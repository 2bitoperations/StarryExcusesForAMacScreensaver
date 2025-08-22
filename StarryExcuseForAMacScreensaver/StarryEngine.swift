import Foundation
import CoreGraphics
import os
import QuartzCore   // For CACurrentMediaTime()
import CoreText     // retained for now; debug overlay not rendered in GPU path
import Darwin       // For task_info CPU sampling
import simd

// Encapsulates the rendering state and logic so both the main ScreenSaverView
// and the configuration sheet preview can share the exact same code path.
struct StarryRuntimeConfig {
    var starsPerUpdate: Int
    var buildingHeight: Double
    var buildingFrequency: Double
    var secsBetweenClears: Double
    var moonTraversalMinutes: Int
    // Replaced min/max radius with a single percentage-based size.
    var moonDiameterScreenWidthPercent: Double
    var moonBrightBrightness: Double
    var moonDarkBrightness: Double
    var moonPhaseOverrideEnabled: Bool
    // 0.0 -> New, 0.5 -> Full, 1.0 -> New (wrap)
    var moonPhaseOverrideValue: Double
    var traceEnabled: Bool
    // Debug: show the illuminated region mask (in red) instead of bright texture
    var showLightAreaTextureFillMask: Bool
    
    // Shooting Stars (extended config)
    var shootingStarsEnabled: Bool
    var shootingStarsAvgSeconds: Double
    var shootingStarsDirectionMode: Int
    var shootingStarsLength: Double
    var shootingStarsSpeed: Double
    var shootingStarsThickness: Double
    var shootingStarsBrightness: Double
    var shootingStarsTrailDecay: Double
    var shootingStarsDebugShowSpawnBounds: Bool
    
    // Satellites (new layer)
    var satellitesEnabled: Bool = true
    var satellitesAvgSpawnSeconds: Double = 0.75
    var satellitesSpeed: Double = 90.0
    var satellitesSize: Double = 2.0
    var satellitesBrightness: Double = 0.9
    var satellitesTrailing: Bool = true
    var satellitesTrailDecay: Double = 0.80
    
    // Debug overlay (FPS / CPU / Time)
    var debugOverlayEnabled: Bool = false
}

// Human-readable dumping for logging/debugging
extension StarryRuntimeConfig: CustomStringConvertible {
    var description: String {
        return """
StarryRuntimeConfig(
  starsPerUpdate: \(starsPerUpdate),
  buildingHeight: \(buildingHeight),
  buildingFrequency: \(buildingFrequency),
  secsBetweenClears: \(secsBetweenClears),
  moonTraversalMinutes: \(moonTraversalMinutes),
  moonDiameterScreenWidthPercent: \(moonDiameterScreenWidthPercent),
  moonBrightBrightness: \(moonBrightBrightness),
  moonDarkBrightness: \(moonDarkBrightness),
  moonPhaseOverrideEnabled: \(moonPhaseOverrideEnabled),
  moonPhaseOverrideValue: \(moonPhaseOverrideValue),
  traceEnabled: \(traceEnabled),
  showLightAreaTextureFillMask: \(showLightAreaTextureFillMask),
  shootingStarsEnabled: \(shootingStarsEnabled),
  shootingStarsAvgSeconds: \(shootingStarsAvgSeconds),
  shootingStarsDirectionMode: \(shootingStarsDirectionMode),
  shootingStarsLength: \(shootingStarsLength),
  shootingStarsSpeed: \(shootingStarsSpeed),
  shootingStarsThickness: \(shootingStarsThickness),
  shootingStarsBrightness: \(shootingStarsBrightness),
  shootingStarsTrailDecay: \(shootingStarsTrailDecay),
  shootingStarsDebugShowSpawnBounds: \(shootingStarsDebugShowSpawnBounds),
  satellitesEnabled: \(satellitesEnabled),
  satellitesAvgSpawnSeconds: \(satellitesAvgSpawnSeconds),
  satellitesSpeed: \(satellitesSpeed),
  satellitesSize: \(satellitesSize),
  satellitesBrightness: \(satellitesBrightness),
  satellitesTrailing: \(satellitesTrailing),
  satellitesTrailDecay: \(satellitesTrailDecay),
  debugOverlayEnabled: \(debugOverlayEnabled)
)
"""
    }
}

final class StarryEngine {
    private let log: OSLog
    private(set) var config: StarryRuntimeConfig
    
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var shootingStarsRenderer: ShootingStarsLayerRenderer?
    private var satellitesRenderer: SatellitesLayerRenderer?
    // Moon renderer (for preview/CoreGraphics path only)
    private var moonRenderer: MoonLayerRenderer?
    
    private var size: CGSize
    private var lastInitSize: CGSize
    
    // Timing
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    
    // FPS computation (smoothed)
    private var fpsAccumulatedTime: CFTimeInterval = 0
    private var fpsFrameCount: Int = 0
    private var currentFPS: Double = 0
    
    // CPU usage sampling
    private var lastProcessCPUTimesSeconds: Double = 0
    private var lastCPUSampleWallTime: CFTimeInterval = 0
    private var currentCPUPercent: Double = 0
    
    // Debug overlay state (not drawn in GPU path yet)
    private let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let debugFont: CTFont = CTFontCreateWithName("Menlo" as CFString, 12, nil)
    private var lastDebugOverlayString: String = ""
    
    // Moon albedo (for renderer upload)
    private var moonAlbedoImage: CGImage?
    private var moonAlbedoDirty: Bool = false
    
    // Headless Metal renderer for preview CGImage output
    private var previewMetalRenderer: StarryMetalRenderer?
    
    // Instrumentation
    private var engineFrameIndex: UInt64 = 0
    private var verboseLogging: Bool = true

    // Force-clear request (e.g., on config change or resize)
    private var forceClearOnNextFrame: Bool = false
    
    init(size: CGSize,
         log: OSLog,
         config: StarryRuntimeConfig) {
        self.size = size
        self.lastInitSize = size
        self.log = log
        self.config = config
        
        // Log full configuration on engine startup for diagnostics
        os_log("StarryEngine initialized with config:\n%{public}@",
               log: log, type: .info, config.description)
        os_log("Initial size: %{public}.0fx%{public}.0f", log: log, type: .info, Double(size.width), Double(size.height))
    }
    
    // MARK: - Resizing
    
    func resizeIfNeeded(newSize: CGSize) {
        guard newSize != lastInitSize, newSize.width > 0, newSize.height > 0 else { return }
        os_log("Resize: %{public}.0fx%{public}.0f -> %{public}.0fx%{public}.0f", log: log, type: .info,
               Double(lastInitSize.width), Double(lastInitSize.height), Double(newSize.width), Double(newSize.height))
        size = newSize
        lastInitSize = newSize
        
        skyline = nil
        skylineRenderer = nil
        shootingStarsRenderer = nil
        satellitesRenderer = nil
        moonRenderer = nil
        previewMetalRenderer = nil
        
        // Moon albedo might change size (radius), request refresh
        moonAlbedoImage = nil
        moonAlbedoDirty = false

        // Ensure persistent GPU layers are cleared on next frame
        forceClearOnNextFrame = true
    }
    
    // MARK: - Configuration
    
    func updateConfig(_ newConfig: StarryRuntimeConfig) {
        let skylineAffecting =
            config.starsPerUpdate != newConfig.starsPerUpdate ||
            config.buildingHeight != newConfig.buildingHeight ||
            config.buildingFrequency != newConfig.buildingFrequency ||
            config.moonTraversalMinutes != newConfig.moonTraversalMinutes ||
            config.moonDiameterScreenWidthPercent != newConfig.moonDiameterScreenWidthPercent ||
            config.moonBrightBrightness != newConfig.moonBrightBrightness ||
            config.moonDarkBrightness != newConfig.moonDarkBrightness ||
            config.moonPhaseOverrideEnabled != newConfig.moonPhaseOverrideEnabled ||
            config.moonPhaseOverrideValue != newConfig.moonPhaseOverrideValue ||
            config.showLightAreaTextureFillMask != newConfig.showLightAreaTextureFillMask
        
        if skylineAffecting {
            os_log("Config changed (skyline affecting) — resetting skyline, renderers, and moon albedo", log: log, type: .info)
            skyline = nil
            skylineRenderer = nil
            moonRenderer = nil
            previewMetalRenderer = nil
            // Force moon albedo refresh
            moonAlbedoImage = nil
            moonAlbedoDirty = false
        }
        
        let shootingStarsAffecting =
            config.shootingStarsEnabled != newConfig.shootingStarsEnabled ||
            config.shootingStarsAvgSeconds != newConfig.shootingStarsAvgSeconds ||
            config.shootingStarsDirectionMode != newConfig.shootingStarsDirectionMode ||
            config.shootingStarsLength != newConfig.shootingStarsLength ||
            config.shootingStarsSpeed != newConfig.shootingStarsSpeed ||
            config.shootingStarsThickness != newConfig.shootingStarsThickness ||
            config.shootingStarsBrightness != newConfig.shootingStarsBrightness ||
            config.shootingStarsTrailDecay != newConfig.shootingStarsTrailDecay ||
            config.shootingStarsDebugShowSpawnBounds != newConfig.shootingStarsDebugShowSpawnBounds
        
        if shootingStarsAffecting {
            os_log("Config changed (shooting-stars affecting) — resetting shootingStarsRenderer", log: log, type: .info)
            shootingStarsRenderer = nil
        }
        
        let satellitesAffecting =
            config.satellitesEnabled != newConfig.satellitesEnabled ||
            config.satellitesAvgSpawnSeconds != newConfig.satellitesAvgSpawnSeconds ||
            config.satellitesSpeed != newConfig.satellitesSpeed ||
            config.satellitesSize != newConfig.satellitesSize ||
            config.satellitesBrightness != newConfig.satellitesBrightness ||
            config.satellitesTrailing != newConfig.satellitesTrailing ||
            config.satellitesTrailDecay != newConfig.satellitesTrailDecay
        
        if satellitesAffecting {
            os_log("Config changed (satellites affecting) — resetting satellitesRenderer", log: log, type: .info)
            satellitesRenderer = nil
        }
        
        config = newConfig
        os_log("New config applied", log: log, type: .info)

        // Any material change should trigger a visual clear of accumulation textures.
        if skylineAffecting || shootingStarsAffecting || satellitesAffecting {
            forceClearOnNextFrame = true
            os_log("Config change will force full clear on next frame", log: log, type: .info)
        }
    }
    
    // MARK: - Initialization of Skyline & Shooting Stars & Satellites
    
    private func ensureSkyline() {
        guard skyline == nil || skylineRenderer == nil else {
            ensureSatellitesRenderer()
            ensureShootingStarsRenderer()
            return
        }
        os_log("Initializing skyline/renderers for size %{public}dx%{public}d", log: log, type: .info, Int(size.width), Int(size.height))
        do {
            let traversalSeconds = Double(config.moonTraversalMinutes) * 60.0
            skyline = try Skyline(screenXMax: Int(size.width),
                                  screenYMax: Int(size.height),
                                  buildingHeightPercentMax: config.buildingHeight,
                                  buildingWidthMin: 40,
                                  buildingWidthMax: 300,
                                  buildingFrequency: config.buildingFrequency,
                                  starsPerUpdate: config.starsPerUpdate,
                                  buildingLightsPerUpdate: 15,
                                  buildingColor: Color(red: 0.972, green: 0.945, blue: 0.012),
                                  flasherRadius: 4,
                                  flasherPeriod: 2.0,
                                  log: log,
                                  clearAfterDuration: config.secsBetweenClears,
                                  traceEnabled: config.traceEnabled,
                                  moonTraversalSeconds: traversalSeconds,
                                  moonBrightBrightness: config.moonBrightBrightness,
                                  moonDarkBrightness: config.moonDarkBrightness,
                                  // percent of screen width
                                  moonDiameterScreenWidthPercent: config.moonDiameterScreenWidthPercent,
                                  moonPhaseOverrideEnabled: config.moonPhaseOverrideEnabled,
                                  moonPhaseOverrideValue: config.moonPhaseOverrideValue)
            if let skyline = skyline {
                os_log("Skyline created. Stars/update=%{public}d, clearAfter=%{public}.1fs", log: log, type: .info, config.starsPerUpdate, config.secsBetweenClears)
                skylineRenderer = SkylineCoreRenderer(skyline: skyline,
                                                      log: log,
                                                      traceEnabled: config.traceEnabled)
                os_log("SkylineCoreRenderer created", log: log, type: .info)
                // Moon renderer for preview (CoreGraphics)
                moonRenderer = MoonLayerRenderer(skyline: skyline,
                                                 log: log,
                                                 brightBrightness: CGFloat(config.moonBrightBrightness),
                                                 darkBrightness: CGFloat(config.moonDarkBrightness),
                                                 showLightAreaTextureFillMask: config.showLightAreaTextureFillMask)
                os_log("MoonLayerRenderer (preview/CG) created", log: log, type: .info)
                // fetch moon albedo once for GPU
                if let tex = skyline.getMoon()?.textureImage {
                    moonAlbedoImage = tex
                    moonAlbedoDirty = true
                    os_log("Fetched moon albedo image for GPU upload (size=%{public}dx%{public}d)", log: log, type: .info, tex.width, tex.height)
                } else {
                    moonAlbedoImage = nil
                    moonAlbedoDirty = false
                    os_log("No moon albedo image available (yet)", log: log, type: .info)
                }
            }
        } catch {
            os_log("StarryEngine: unable to init skyline %{public}@", log: log, type: .fault, "\(error)")
        }
        ensureSatellitesRenderer()
        ensureShootingStarsRenderer()
    }
    
    private func ensureShootingStarsRenderer() {
        guard shootingStarsRenderer == nil,
              config.shootingStarsEnabled,
              let skyline = skyline else { return }
        shootingStarsRenderer = ShootingStarsLayerRenderer(
            width: Int(size.width),
            height: Int(size.height),
            skyline: skyline,
            log: log,
            avgSeconds: config.shootingStarsAvgSeconds,
            directionModeRaw: config.shootingStarsDirectionMode,
            length: CGFloat(config.shootingStarsLength),
            speed: CGFloat(config.shootingStarsSpeed),
            thickness: CGFloat(config.shootingStarsThickness),
            brightness: CGFloat(config.shootingStarsBrightness),
            trailDecay: CGFloat(config.shootingStarsTrailDecay),
            debugShowSpawnBounds: config.shootingStarsDebugShowSpawnBounds)
        os_log("ShootingStarsLayerRenderer created (enabled=%{public}@, avg=%{public}.2fs)", log: log, type: .info, config.shootingStarsEnabled ? "true" : "false", config.shootingStarsAvgSeconds)
    }
    
    private func ensureSatellitesRenderer() {
        guard satellitesRenderer == nil,
              config.satellitesEnabled,
              skyline != nil else { return }
        satellitesRenderer = SatellitesLayerRenderer(width: Int(size.width),
                                                     height: Int(size.height),
                                                     log: log,
                                                     avgSpawnSeconds: config.satellitesAvgSpawnSeconds,
                                                     speed: CGFloat(config.satellitesSpeed),
                                                     size: CGFloat(config.satellitesSize),
                                                     brightness: CGFloat(config.satellitesBrightness),
                                                     trailing: config.satellitesTrailing,
                                                     trailDecay: CGFloat(config.satellitesTrailDecay))
        os_log("SatellitesLayerRenderer created (enabled=%{public}@, avg=%{public}.2fs)", log: log, type: .info, config.satellitesEnabled ? "true" : "false", config.satellitesAvgSpawnSeconds)
    }
    
    // MARK: - Frame Advancement (GPU path)
    
    func advanceFrameGPU() -> StarryDrawData {
        engineFrameIndex &+= 1
        let logThisFrame = verboseLogging && (engineFrameIndex <= 5 || engineFrameIndex % 60 == 0)
        if logThisFrame {
            os_log("advanceFrameGPU: begin frame #%{public}llu", log: log, type: .info, engineFrameIndex)
        }
        
        ensureSkyline()
        let now = CACurrentMediaTime()
        let dt = max(0.0, now - lastFrameTime)
        lastFrameTime = now
        
        updateFPS(dt: dt)
        sampleCPU(dt: dt)
        
        var clearAll = false
        var baseSprites: [SpriteInstance] = []
        var satellitesSprites: [SpriteInstance] = []
        var shootingSprites: [SpriteInstance] = []
        var satellitesKeep: Float = 0.0
        var shootingKeep: Float = 0.0
        
        if let skyline = skyline,
           let skylineRenderer = skylineRenderer {
            if skyline.shouldClearNow() {
                os_log("advanceFrameGPU: skyline requested clear — resetting state", log: log, type: .info)
                skylineRenderer.resetFrameCounter()
                satellitesRenderer?.reset()
                shootingStarsRenderer?.reset()
                self.skyline = nil
                self.skylineRenderer = nil
                self.shootingStarsRenderer = nil
                self.satellitesRenderer = nil
                self.moonRenderer = nil
                clearAll = true
                ensureSkyline()
            }
            
            // Base sprites (accumulate on persistent texture)
            baseSprites = skylineRenderer.generateSprites()
            
            if config.satellitesEnabled, let sat = satellitesRenderer {
                let (sprites, keep) = sat.update(dt: dt)
                satellitesSprites = sprites
                satellitesKeep = keep
            } else {
                satellitesSprites.removeAll()
                satellitesKeep = 0.0
            }
            
            if config.shootingStarsEnabled, let ss = shootingStarsRenderer {
                let (sprites, keep) = ss.update(dt: dt)
                shootingSprites = sprites
                shootingKeep = keep
            } else {
                shootingSprites.removeAll()
                shootingKeep = 0.0
            }
        } else {
            clearAll = true
        }

        // Honor a forced clear (e.g., config change or resize)
        if forceClearOnNextFrame {
            os_log("advanceFrameGPU: forceClearOnNextFrame active — will clear accumulation textures", log: log, type: .info)
            clearAll = true
            satellitesKeep = 0.0
            shootingKeep = 0.0
            forceClearOnNextFrame = false
        }
        
        // Moon params
        var moonParams: MoonParams?
        if let moon = skyline?.getMoon() {
            let c = moon.currentCenter()
            let centerPx = SIMD2<Float>(Float(c.x), Float(c.y))
            let r = Float(moon.radius)
            let f = Float(moon.illuminatedFraction)
            moonParams = MoonParams(centerPx: centerPx,
                                    radiusPx: r,
                                    phaseFraction: f,
                                    brightBrightness: Float(config.moonBrightBrightness),
                                    darkBrightness: Float(config.moonDarkBrightness))
        }
        
        if logThisFrame {
            os_log("advanceFrameGPU: sprites base=%{public}d sat=%{public}d shoot=%{public}d keep sat=%{public}.3f shoot=%{public}.3f moon=%{public}@ clearAll=%{public}@",
                   log: log, type: .info,
                   baseSprites.count, satellitesSprites.count, shootingSprites.count,
                   Double(satellitesKeep), Double(shootingKeep),
                   moonParams != nil ? "yes" : "no",
                   clearAll ? "yes" : "no")
        }
        
        let drawData = StarryDrawData(
            size: size,
            clearAll: clearAll,
            baseSprites: baseSprites,
            satellitesSprites: satellitesSprites,
            satellitesKeepFactor: satellitesKeep,
            shootingSprites: shootingSprites,
            shootingKeepFactor: shootingKeep,
            moon: moonParams,
            moonAlbedoImage: moonAlbedoDirty ? moonAlbedoImage : nil,
            showLightAreaTextureFillMask: config.showLightAreaTextureFillMask
        )
        // Only send albedo once until skyline/moon changes
        if moonAlbedoDirty && logThisFrame {
            os_log("advanceFrameGPU: moon albedo image attached for upload", log: log, type: .info)
        }
        moonAlbedoDirty = false
        return drawData
    }
    
    // MARK: - Frame Advancement (Preview via Metal headless)
    // Produce a CGImage by rendering through the same Metal renderer into an offscreen texture.
    
    @discardableResult
    func advanceFrame() -> CGImage? {
        engineFrameIndex &+= 1
        let logThisFrame = verboseLogging && (engineFrameIndex <= 5 || engineFrameIndex % 60 == 0)
        if logThisFrame {
            os_log("advanceFrame (headless): begin frame #%{public}llu", log: log, type: .info, engineFrameIndex)
        }
        
        ensureSkyline()
        let now = CACurrentMediaTime()
        let dt = max(0.0, now - lastFrameTime)
        lastFrameTime = now
        
        updateFPS(dt: dt)
        sampleCPU(dt: dt)
        
        // Generate the same drawData used by the on-screen GPU path
        var clearAll = false
        var baseSprites: [SpriteInstance] = []
        var satellitesSprites: [SpriteInstance] = []
        var shootingSprites: [SpriteInstance] = []
        var satellitesKeep: Float = 0.0
        var shootingKeep: Float = 0.0
        
        if let skyline = skyline,
           let skylineRenderer = skylineRenderer {
            if skyline.shouldClearNow() {
                os_log("advanceFrame(headless): skyline requested clear — resetting state", log: log, type: .info)
                skylineRenderer.resetFrameCounter()
                satellitesRenderer?.reset()
                shootingStarsRenderer?.reset()
                self.skyline = nil
                self.skylineRenderer = nil
                self.shootingStarsRenderer = nil
                self.satellitesRenderer = nil
                self.moonRenderer = nil
                clearAll = true
                ensureSkyline()
            }
            
            baseSprites = skylineRenderer.generateSprites()
            
            if config.satellitesEnabled, let sat = satellitesRenderer {
                let (spr, keep) = sat.update(dt: dt)
                satellitesSprites = spr
                satellitesKeep = keep
            }
            if config.shootingStarsEnabled, let ss = shootingStarsRenderer {
                let (spr, keep) = ss.update(dt: dt)
                shootingSprites = spr
                shootingKeep = keep
            }
        } else {
            clearAll = true
        }

        // Honor a forced clear (e.g., config change or resize)
        if forceClearOnNextFrame {
            os_log("advanceFrame(headless): forceClearOnNextFrame active — will clear accumulation textures", log: log, type: .info)
            clearAll = true
            satellitesKeep = 0.0
            shootingKeep = 0.0
            forceClearOnNextFrame = false
        }
        
        // Moon params
        var moonParams: MoonParams?
        if let moon = skyline?.getMoon() {
            let c = moon.currentCenter()
            let centerPx = SIMD2<Float>(Float(c.x), Float(c.y))
            let r = Float(moon.radius)
            let f = Float(moon.illuminatedFraction)
            moonParams = MoonParams(centerPx: centerPx,
                                    radiusPx: r,
                                    phaseFraction: f,
                                    brightBrightness: Float(config.moonBrightBrightness),
                                    darkBrightness: Float(config.moonDarkBrightness))
        }
        
        if logThisFrame {
            os_log("advanceFrame(headless): sprites base=%{public}d sat=%{public}d shoot=%{public}d keep sat=%{public}.3f shoot=%{public}.3f moon=%{public}@ clearAll=%{public}@",
                   log: log, type: .info,
                   baseSprites.count, satellitesSprites.count, shootingSprites.count,
                   Double(satellitesKeep), Double(shootingKeep),
                   moonParams != nil ? "yes" : "no",
                   clearAll ? "yes" : "no")
        }
        
        let drawData = StarryDrawData(
            size: size,
            clearAll: clearAll,
            baseSprites: baseSprites,
            satellitesSprites: satellitesSprites,
            satellitesKeepFactor: satellitesKeep,
            shootingSprites: shootingSprites,
            shootingKeepFactor: shootingKeep,
            moon: moonParams,
            moonAlbedoImage: moonAlbedoDirty ? moonAlbedoImage : nil,
            showLightAreaTextureFillMask: config.showLightAreaTextureFillMask
        )
        if moonAlbedoDirty && logThisFrame {
            os_log("advanceFrame(headless): moon albedo image attached for upload", log: log, type: .info)
        }
        moonAlbedoDirty = false
        
        if previewMetalRenderer == nil {
            os_log("Creating headless StarryMetalRenderer", log: log, type: .info)
            previewMetalRenderer = StarryMetalRenderer(log: log)
        }
        guard let renderer = previewMetalRenderer else {
            os_log("Headless render failed: previewMetalRenderer is nil", log: log, type: .error)
            return nil
        }
        renderer.updateDrawableSize(size: size, scale: 1.0)
        let img = renderer.renderToImage(drawData: drawData)
        if img == nil {
            os_log("Headless renderer returned nil CGImage", log: log, type: .error)
        } else if logThisFrame {
            os_log("Headless renderer returned CGImage", log: log, type: .info)
        }
        return img
    }
    
    private func rgbaFromPremulRGBA(_ v: SIMD4<Float>) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let a = CGFloat(max(0.0, min(1.0, v.w)))
        if a <= 0 { return (0, 0, 0, 0) }
        let r = CGFloat(v.x) / a
        let g = CGFloat(v.y) / a
        let b = CGFloat(v.z) / a
        return (max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)), a)
    }
    
    private func makeBlackImage(size: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
    
    // MARK: - CPU/FPS
    
    private func sampleCPU(dt: CFTimeInterval) {
        guard dt > 0 else { return }
        var info = task_thread_times_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &infoCount)
            }
        }
        
        var cpuSeconds: Double = 0
        if kerr == KERN_SUCCESS {
            let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000.0
            let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000.0
            cpuSeconds = user + system
        } else {
            return
        }
        
        if lastProcessCPUTimesSeconds == 0 {
            lastProcessCPUTimesSeconds = cpuSeconds
            lastCPUSampleWallTime = CACurrentMediaTime()
            return
        }
        let deltaCPU = max(0, cpuSeconds - lastProcessCPUTimesSeconds)
        let percent = (deltaCPU / dt) * 100.0
        currentCPUPercent = currentCPUPercent * 0.8 + percent * 0.2
        lastProcessCPUTimesSeconds = cpuSeconds
        lastCPUSampleWallTime = CACurrentMediaTime()
    }
    
    private func updateFPS(dt: CFTimeInterval) {
        fpsFrameCount += 1
        fpsAccumulatedTime += dt
        if fpsAccumulatedTime >= 0.5 {
            let fps = Double(fpsFrameCount) / fpsAccumulatedTime
            currentFPS = currentFPS * 0.6 + fps * 0.4
            fpsAccumulatedTime = 0
            fpsFrameCount = 0
            lastDebugOverlayString = String(format: "FPS: %.1f  CPU: %.1f%%  Time: %@", currentFPS, currentCPUPercent, isoDateFormatter.string(from: Date()))
            os_log("Stats: FPS=%.1f CPU=%.1f%%", log: log, type: .debug, currentFPS, currentCPUPercent)
        }
    }
}
