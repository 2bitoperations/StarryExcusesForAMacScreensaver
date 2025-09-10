import Foundation
import Metal
import QuartzCore
import CoreGraphics
import ImageIO
import os
import simd
import AppKit   // For font & text drawing of debug overlay (macOS only)

final class StarryMetalRenderer {
    
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
        var params0: SIMD4<Float> // x=radius, y=illuminatedFraction, z=bright, w=dark
        var params1: SIMD4<Float> // x=debugMaskFlag, y=waxingSign (+1 / -1), z/w unused
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
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var metalLayer: CAMetalLayer?
    private let log: OSLog
    
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
    private var moonAlbedoHasMipmaps: Bool = false
    
    private var offscreenComposite: MTLTexture?
    private var offscreenSize: CGSize = .zero
    
    private var lastAppliedDrawableSize: CGSize = .zero
    
    // Renderer-side explicit overlay toggle (e.g. from preview UI)
    private var userOverlayEnabled: Bool = false
    // Value coming from the engine draw data each frame
    private var engineOverlayEnabled: Bool = false
    // Effective OR of the two (used for actual drawing)
    private var effectiveOverlayEnabled: Bool = false
    
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
    private var dumpLayersNextFrame: Bool = false
    
    // --- Debug Overlay State ---
    private var overlayTexture: MTLTexture?
    private var overlayQuadVertexBuffer: MTLBuffer?
    private var lastOverlayString: String = ""
    private var lastOverlayUpdateTime: CFTimeInterval = 0
    private var overlayWidthPx: Int = 0
    private var overlayHeightPx: Int = 0
    private let overlayUpdateInterval: CFTimeInterval = 0.25  // seconds
    private var lastOverlayDrawnFrame: UInt64 = 0
    private var lastOverlayLogTime: CFTimeInterval = 0
    
    private let notificationCenters: [NotificationCenter] = [
        NotificationCenter.default,
        DistributedNotificationCenter.default()
    ]
    
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
    
    private func installDebugObservers() {
        guard !debugObserversInstalled else { return }
        addObserver(name: Self.debugCompositeModeNotification, selector: #selector(handleCompositeModeNotification(_:)))
        addObserver(name: Self.diagnosticsNotification, selector: #selector(handleDiagnosticsNotification(_:)))
        addObserver(name: Self.clearNotification, selector: #selector(handleClearNotification(_:)))
        debugObserversInstalled = true
    }
    
    private func addObserver(name: Notification.Name, selector: Selector) {
        for center in notificationCenters {
            center.addObserver(self, selector: selector, name: name, object: nil)
        }
    }
    
    @objc private func handleCompositeModeNotification(_ note: Notification) {
        processCompositeMode(userInfo: note.userInfo)
    }
    
    @objc private func handleDiagnosticsNotification(_ note: Notification) {
        processDiagnostics(userInfo: note.userInfo)
    }
    
    @objc private func handleClearNotification(_ note: Notification) {
        processClear(userInfo: note.userInfo)
    }
    
    private func processCompositeMode(userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?["mode"] as? Int,
              let mode = CompositeDebugMode(rawValue: raw) else {
            os_log("CompositeMode notification: invalid or missing 'mode'", log: log, type: .error)
            return
        }
        debugCompositeMode = mode
        os_log("Debug: composite mode changed via notification to %{public}@",
               log: log, type: .info,
               mode == .normal ? "NORMAL" : (mode == .satellitesOnly ? "SATELLITES-ONLY" : "BASE-ONLY"))
    }
    
    private func processDiagnostics(userInfo ui: [AnyHashable: Any]?) {
        var applied: [String] = []
        var ignored: [String] = []
        
        struct Keys {
            static let enabled = "enabled"
            static let everyNFrames = "everyNFrames"
            static let debugLogEveryN = "debugLogEveryN"
            static let skipSat = "skipSatellitesDraw"
            static let overlay = "overlayEnabled"
            static let satHalf = "satellitesHalfLifeSeconds"
            static let shootHalf = "shootingHalfLifeSeconds"
            static let dropBaseN = "dropBaseEveryN"
            static let dumpLayers = "dumpLayersNextFrame"
        }
        
        let legacyIgnoredKeys: [String] = [
            "starsPerUpdate",
            "buildingLightsPerUpdate",
            "gpuCaptureStart",
            "gpuCaptureStop",
            "gpuCaptureFrames",
            "gpuCapturePath"
        ]
        
        if let v: Bool = value(Keys.enabled, from: ui) {
            diagnosticsEnabled = v
            applied.append("diagnosticsEnabled=\(v)")
        }
        if let n: Int = value(Keys.everyNFrames, from: ui) ?? value(Keys.debugLogEveryN, from: ui) {
            diagnosticsEveryNFrames = max(1, n)
            applied.append("diagnosticsEveryNFrames=\(diagnosticsEveryNFrames)")
        }
        if let v: Bool = value(Keys.skipSat, from: ui) {
            debugSkipSatellitesDraw = v
            applied.append("skipSatellitesDraw=\(v)")
        }
        if let v: Bool = value(Keys.overlay, from: ui) {
            // This sets the user (renderer) overlay toggle directly
            userOverlayEnabled = v
            applied.append("userOverlayEnabled=\(v)")
        }
        if let d: Double = value(Keys.satHalf, from: ui) {
            satellitesHalfLifeSeconds = max(1e-6, d)
            applied.append(String(format: "satellitesHalfLife=%.4f", satellitesHalfLifeSeconds))
        }
        if let d: Double = value(Keys.shootHalf, from: ui) {
            shootingHalfLifeSeconds = max(1e-6, d)
            applied.append(String(format: "shootingHalfLife=%.4f", shootingHalfLifeSeconds))
        }
        if let n: Int = value(Keys.dropBaseN, from: ui) {
            dropBaseEveryNFrames = max(0, n)
            applied.append("dropBaseEveryN=\(dropBaseEveryNFrames)")
        }
        if let dump: Bool = value(Keys.dumpLayers, from: ui), dump {
            dumpLayersNextFrame = true
            applied.append("dumpLayersNextFrame")
        }
        
        if let ui = ui {
            for k in legacyIgnoredKeys where ui[k] != nil {
                ignored.append(k)
            }
        }
        
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
    
    private func processClear(userInfo ui: [AnyHashable: Any]?) {
        let target: String = (ui?["target"] as? String)?.lowercased() ?? "all"
        if target == "all" {
            clearOffscreenTextures(reason: "Notification(all)")
            return
        }
        guard let cb = commandQueue.makeCommandBuffer() else {
            os_log("Clear notification: failed to make command buffer", log: log, type: .error)
            return
        }
        func clr(_ t: MTLTexture?, label: String) {
            guard let t else { return }
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
            os_log("updateDrawableSize: allocated and cleared layer textures for size %.0fx%.0f",
                   log: log, type: .info, Double(size.width), Double(size.height))
            if metalLayer == nil {
                offscreenComposite = nil
                offscreenSize = .zero
            }
        }
    }
    
    // External (UI) toggle (preview sheet)
    func setDebugOverlayEnabled(_ enabled: Bool) {
        if userOverlayEnabled != enabled {
            os_log("Renderer user overlay toggle now %{public}@", log: log, type: .info, enabled ? "ENABLED" : "disabled")
        }
        userOverlayEnabled = enabled
        recomputeEffectiveOverlayEnabled()
    }
    
    private func recomputeEffectiveOverlayEnabled() {
        let previous = effectiveOverlayEnabled
        effectiveOverlayEnabled = (engineOverlayEnabled || userOverlayEnabled)
        if previous != effectiveOverlayEnabled {
            os_log("Effective overlay visibility now %{public}@ (engine=%{public}@ user=%{public}@)",
                   log: log, type: .info,
                   effectiveOverlayEnabled ? "ON" : "off",
                   engineOverlayEnabled ? "ON" : "off",
                   userOverlayEnabled ? "ON" : "off")
        }
    }
    
    func setDiagnostics(enabled: Bool, everyNFrames: Int = 60) {
        diagnosticsEnabled = enabled
        diagnosticsEveryNFrames = max(1, everyNFrames)
        os_log("Diagnostics %@", log: log, type: .info, enabled ? "ENABLED" : "disabled")
    }
    
    func setSkipSatellitesDrawingForDebug(_ skip: Bool) {
        debugSkipSatellitesDraw = skip
        os_log("Debug: skip satellites draw is %@", log: log, type: .info, skip ? "ON" : "off")
    }
    
    func setCompositeSatellitesOnlyForDebug(_ enabled: Bool) {
        let wasSatOnly = (debugCompositeMode == .satellitesOnly)
        debugCompositeMode = enabled ? .satellitesOnly : .normal
        os_log("Debug: composite mode set to %@", log: log, type: .info,
               enabled ? "SATELLITES-ONLY" : "NORMAL")
        if wasSatOnly && !enabled {
            debugClearBasePending = true
            os_log("Debug: scheduling one-time BASE clear on next frame (leaving satellites-only)", log: log, type: .info)
        }
    }
    
    func setCompositeBaseOnlyForDebug(_ enabled: Bool) {
        debugCompositeMode = enabled ? .baseOnly : .normal
        os_log("Debug: composite mode set to %@", log: log, type: .info, enabled ? "BASE-ONLY" : "NORMAL")
    }
    
    func setTrailHalfLives(satellites: Double?, shooting: Double?) {
        satellitesHalfLifeSeconds = satellites ?? 0.5
        shootingHalfLifeSeconds = shooting ?? 0.5
        os_log("Trail half-lives updated: satellites=%.3f s, shooting=%.3f s",
               log: log, type: .info, satellitesHalfLifeSeconds, shootingHalfLifeSeconds)
    }
    
    // MARK: - Moon Albedo (Mipmapped) Upload
    
    func setMoonAlbedo(image: CGImage) {
        let width = image.width
        theight: do {
            let height = image.height
            guard width > 0, height > 0 else { return }
            os_log("setMoonAlbedo: preparing upload (%dx%d) mipmapped", log: log, type: .info, width, height)
            
            if moonAlbedoTexture == nil ||
                moonAlbedoTexture!.width != width ||
                moonAlbedoTexture!.height != height ||
                !moonAlbedoHasMipmaps {
                let dstDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                       width: width,
                                                                       height: height,
                                                                       mipmapped: true)
                dstDesc.usage = [.shaderRead]
                dstDesc.storageMode = .private
                moonAlbedoTexture = device.makeTexture(descriptor: dstDesc)
                moonAlbedoTexture?.label = "MoonAlbedo (private,mips)"
                moonAlbedoHasMipmaps = true
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
        }
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
        
        // Update engine-derived overlay flag, then recompute effective
        engineOverlayEnabled = drawData.debugOverlayEnabled
        recomputeEffectiveOverlayEnabled()
        
        // (Do not overwrite userOverlayEnabled here; we maintain both)
        if effectiveOverlayEnabled && !drawData.debugOverlayEnabled && userOverlayEnabled {
            os_log("Overlay active via user override (engine reports disabled)", log: log, type: .info)
        } else if drawData.debugOverlayEnabled {
            os_log("Overlay active via engine flag", log: log, type: .debug)
        }
        
        updateOverlayIfNeeded(drawData: drawData, effectiveEnabled: effectiveOverlayEnabled)
        
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
            drawData.clearAll == false &&
            !(effectiveOverlayEnabled && overlayTexture != nil)
        if nothingToDraw {
            // Early out only if overlay is not (yet) drawable
            return
        }
        
        logFrameDiagnostics(prefix: "", drawData: drawData, dt: dt)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Starry Frame CommandBuffer"
        
        if moonAlbedoNeedsBlit,
           let staging = moonAlbedoStagingTexture,
           let dst = moonAlbedoTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Blit+Mips MoonAlbedo staging->private"
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
                blit.generateMipmaps(for: dst)
                blit.endEncoding()
                os_log("render: enqueued moon albedo blit + mip gen (%dx%d)", log: log, type: .info, dst.width, dst.height)
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
        
        engineOverlayEnabled = drawData.debugOverlayEnabled
        recomputeEffectiveOverlayEnabled()
        if effectiveOverlayEnabled && !drawData.debugOverlayEnabled && userOverlayEnabled {
            os_log("Overlay active via user override (headless)", log: log, type: .info)
        }
        updateOverlayIfNeeded(drawData: drawData, effectiveEnabled: effectiveOverlayEnabled)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        commandBuffer.label = "Starry Headless CommandBuffer"
        
        if moonAlbedoNeedsBlit,
           let staging = moonAlbedoStagingTexture,
           let dst = moonAlbedoTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Blit+Mips MoonAlbedo staging->private (headless)"
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
                blit.generateMipmaps(for: dst)
                blit.endEncoding()
                os_log("renderToImage: enqueued moon albedo blit + mip gen (%dx%d)", log: log, type: .info, dst.width, dst.height)
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
    
    private func encodeScenePasses(commandBuffer: MTLCommandBuffer,
                                   drawData: StarryDrawData,
                                   dt: CFTimeInterval?,
                                   headless: Bool) {
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
        encoder.pushDebugGroup(headless ? "Headless Composite+Moon+Overlay" : "Composite+Moon+Overlay")
        
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
                params0: SIMD4<Float>(moon.radiusPx,
                                      moon.phaseFraction,
                                      moon.brightBrightness,
                                      moon.darkBrightness),
                params1: SIMD4<Float>(drawData.showLightAreaTextureFillMask ? 1.0 : 0.0,
                                      moon.waxingSign,
                                      0, 0)
            )
            encoder.setVertexBytes(&uni, length: MemoryLayout<MoonUniformsSwift>.stride, index: 2)
            encoder.setFragmentBytes(&uni, length: MemoryLayout<MoonUniformsSwift>.stride, index: 2)
            if let albedo = moonAlbedoTexture {
                encoder.setFragmentTexture(albedo, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        
        if effectiveOverlayEnabled, let overlayTex = overlayTexture, let overlayVB = overlayQuadVertexBuffer {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setVertexBuffer(overlayVB, offset: 0, index: 0)
            encoder.setFragmentTexture(overlayTex, index: 0)
            encoder.setFragmentBytes(&whiteTint,
                                     length: MemoryLayout<SIMD4<Float>>.stride,
                                     index: FragmentBufferIndex.quadUniforms)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            lastOverlayDrawnFrame = frameIndex
            let now = CACurrentMediaTime()
            if now - lastOverlayLogTime > 2.0 {
                os_log("Overlay drawn (frame=%{public}llu size=%{public}dx%{public}d text=\"%{public}@\" eff=%{public}@ engine=%{public}@ user=%{public}@)",
                       log: log, type: .info,
                       frameIndex, overlayTex.width, overlayTex.height, lastOverlayString,
                       effectiveOverlayEnabled ? "ON" : "off",
                       engineOverlayEnabled ? "ON" : "off",
                       userOverlayEnabled ? "ON" : "off")
                lastOverlayLogTime = now
            }
        }
        
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
    
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
        
        os_log("Allocated textures: base=%@ baseScratch=%@ sat=%@ satScratch=%@ shoot=%@ shootScratch=%@",
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
        os_log("ClearOffscreenTextures: begin (reason=%@)", log: log, type: .info, reason)
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
        os_log("ClearOffscreenTextures: complete (reason=%@)", log: log, type: .info, reason)
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
            os_log("uploadSpriteInstances: allocation failed provenance=%@ bytes=%d",
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
        
        guard let deviceBuffer = uploadSpriteInstances(sprites,
                                                       provenance: provenance,
                                                       commandBuffer: commandBuffer) else { return }
        
        if (pipeline === spriteAdditivePipeline) &&
            (isSameTexture(target, layerTex.base) ||
             isSameTexture(target, layerTex.baseScratch) ||
             labelContains(target, "BaseLayer")) {
            os_log("ALERT: Skipping additive draw into BaseLayer (provenance=%@)", log: log, type: .fault, provenanceString(provenance))
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
            os_log("Decay in-place %@ keep=%.4f (halfLife=%.3f dt=%.4f)",
                   log: log, type: .debug,
                   (which == .satellites ? "satellites" : "shooting"),
                   keep, halfLife, (dt ?? 0))
        }
        
        let target: MTLTexture? = (which == .satellites) ? layerTex.satellites : layerTex.shooting
        guard let tex = target else {
            os_log("applyDecay: missing target texture for %@ layer", log: log, type: .error, which == .satellites ? "satellites" : "shooting")
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
    
    // MARK: - Debug Overlay (text -> texture)
    
    private func updateOverlayIfNeeded(drawData: StarryDrawData, effectiveEnabled: Bool) {
        guard effectiveEnabled else { return }
        let now = CACurrentMediaTime()
        let fps = drawData.debugFPS
        let cpu = drawData.debugCPUPercent
        let overlayStr = String(format: "FPS: %.1f  CPU: %.1f%%", fps, cpu)
        let changed = (overlayStr != lastOverlayString)
        if !changed && (now - lastOverlayUpdateTime) < overlayUpdateInterval {
            return
        }
        lastOverlayString = overlayStr
        lastOverlayUpdateTime = now
        
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        // Fuchsia text color (bright magenta) for visibility testing
        let fuchsia = NSColor(calibratedRed: 1.0, green: 0.0, blue: 1.0, alpha: 1.0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fuchsia
        ]
        let textSize = (overlayStr as NSString).size(withAttributes: attributes)
        let padH: CGFloat = 8
        let padV: CGFloat = 4
        let texWidth = Int(ceil(textSize.width + padH * 2))
        let texHeight = Int(ceil(textSize.height + padV * 2))
        
        let maxW = 1024
        let maxH = 256
        overlayWidthPx = min(texWidth, maxW)
        overlayHeightPx = min(texHeight, maxH)
        let rowBytes = overlayWidthPx * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * overlayHeightPx)
        
        if let ctx = CGContext(data: &bytes,
                               width: overlayWidthPx,
                               height: overlayHeightPx,
                               bitsPerComponent: 8,
                               bytesPerRow: rowBytes,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.clear(CGRect(x: 0, y: 0, width: overlayWidthPx, height: overlayHeightPx))
            // Dark semi-transparent background
            ctx.setFillColor(NSColor(calibratedRed: 0.05, green: 0.0, blue: 0.08, alpha: 0.55).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: overlayWidthPx, height: overlayHeightPx))
            
            // IMPORTANT: AppKit text drawing APIs require an NSGraphicsContext bound to the CGContext.
            // Without this, the previous implementation produced only the background rectangle (no text).
            let nsGC = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsGC
            // Draw text
            let textOrigin = CGPoint(x: padH, y: padV)
            (overlayStr as NSString).draw(at: textOrigin, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        
        if overlayTexture == nil ||
            overlayTexture!.width != overlayWidthPx ||
            overlayTexture!.height != overlayHeightPx {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: overlayWidthPx,
                                                                height: overlayHeightPx,
                                                                mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            overlayTexture = device.makeTexture(descriptor: desc)
            overlayTexture?.label = "DebugOverlay"
        }
        if let tex = overlayTexture {
            let region = MTLRegionMake2D(0, 0, overlayWidthPx, overlayHeightPx)
            tex.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: rowBytes)
        }
        
        os_log("Overlay updated (size=%dx%d text=\"%{public}@\" eff=%{public}@ engine=%{public}@ user=%{public}@ color=fuchsia)",
               log: log, type: .info, overlayWidthPx, overlayHeightPx, overlayStr,
               effectiveOverlayEnabled ? "ON" : "off",
               engineOverlayEnabled ? "ON" : "off",
               userOverlayEnabled ? "ON" : "off")
        buildOverlayQuadIfNeeded(screenSize: drawData.size)
    }
    
    private func buildOverlayQuadIfNeeded(screenSize: CGSize) {
        guard overlayWidthPx > 0, overlayHeightPx > 0 else { return }
        let margin: CGFloat = 8
        let W = screenSize.width
        let H = screenSize.height
        guard W > 0 && H > 0 else { return }
        let x0: CGFloat = margin
        let y0: CGFloat = margin
        let x1: CGFloat = min(x0 + CGFloat(overlayWidthPx), W)
        let y1: CGFloat = min(y0 + CGFloat(overlayHeightPx), H)
        
        func toClipX(_ x: CGFloat) -> Float { return Float((x / W) * 2.0 - 1.0) }
        func toClipY(_ y: CGFloat) -> Float { return Float(1.0 - (y / H) * 2.0) }
        
        let tl = SIMD2<Float>(toClipX(x0), toClipY(y0))
        let tr = SIMD2<Float>(toClipX(x1), toClipY(y0))
        let bl = SIMD2<Float>(toClipX(x0), toClipY(y1))
        let br = SIMD2<Float>(toClipX(x1), toClipY(y1))
        
        struct V { var p: SIMD2<Float>; var t: SIMD2<Float> }
        let verts: [V] = [
            V(p: bl, t: [0, 1]),
            V(p: br, t: [1, 1]),
            V(p: tl, t: [0, 0]),
            V(p: tl, t: [0, 0]),
            V(p: br, t: [1, 1]),
            V(p: tr, t: [1, 0])
        ]
        if overlayQuadVertexBuffer == nil ||
            overlayQuadVertexBuffer!.length < MemoryLayout<V>.stride * verts.count {
            overlayQuadVertexBuffer = device.makeBuffer(bytes: verts,
                                                        length: MemoryLayout<V>.stride * verts.count,
                                                        options: .storageModeShared)
            overlayQuadVertexBuffer?.label = "OverlayQuad"
        } else {
            memcpy(overlayQuadVertexBuffer!.contents(), verts, MemoryLayout<V>.stride * verts.count)
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
            os_log("PNG save: failed to create destination for %@", log: log, type: .error, url.path)
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            os_log("PNG saved -> %@", log: log, type: .info, url.path)
        } else {
            os_log("PNG save failed -> %@", log: log, type: .error, url.path)
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
        theight: do { _ = snapshot(layerTex.satellitesScratch) }
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
            os_log("DumpLayers: failed to create directory %@ (%@)",
                   log: log, type: .error, dir.path, "\(error)")
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            func write(_ tex: MTLTexture?, name: String) {
                guard let tex, let img = self.textureToImage(tex) else { return }
                let filename = "\(name)-\(tex.label ?? "tex")-\(self.ptrString(tex)).png"
                let url = dir.appendingPathComponent(filename, isDirectory: false)
                self.savePNG(img, to: url)
            }
            write(baseSnap, name: "Base")
            write(satSnap, name: "Sat")
            write(satScratchSnap, name: "SatScratch")
            write(shootSnap, name: "Shoot")
            write(shootScratchSnap, name: "ShootScratch")
            os_log("DumpLayers: completed -> %@", log: self.log, type: .info, dir.path)
        }
    }
    
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
        os_log("%@Frame #%llu dt=%.4f s | satSprites=%d alphaSamples=%@ shootSprites=%d keep(sat)=%.4f keep(shoot)=%.4f overlay(eff=%{public}@ engine=%{public}@ user=%{public}@ tex=%{public}@)",
               log: log, type: .debug,
               prefix, frameIndex, dtSec, satCount, alphaSamples.description, shootCount, keepSat, keepShoot,
               (effectiveOverlayEnabled ? "ON" : "off"),
               (engineOverlayEnabled ? "ON" : "off"),
               (userOverlayEnabled ? "ON" : "off"),
               (overlayTexture != nil ? "yes" : "no"))
    }
}
