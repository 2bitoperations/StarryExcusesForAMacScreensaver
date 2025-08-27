import Foundation
import CoreGraphics
import os
import QuartzCore   // For CACurrentMediaTime()
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

    // --- Engine-side diagnostics to prove/disprove base contamination ---
    // If > 0, every Nth frame we will intentionally drop all baseSprites for that frame.
    // If the renderer then logs "ALERT: Base changed in frame with zero baseSprites",
    // it proves that something else (e.g., trails) touched the base layer.
    var debugDropBaseEveryNFrames: Int = 0
    // If > 0, schedule a full clear (clearAll) every Nth frame. This should
    // reset all accumulation textures and, combined with renderer-side clear readbacks,
    // verifies that clears are actually executed.
    var debugForceClearEveryNFrames: Int = 0
    // If true, log per frame (not just first few/every 60) to correlate events tightly.
    var debugLogEveryFrame: Bool = false
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
  debugOverlayEnabled: \(debugOverlayEnabled),
  debugDropBaseEveryNFrames: \(debugDropBaseEveryNFrames),
  debugForceClearEveryNFrames: \(debugForceClearEveryNFrames),
  debugLogEveryFrame: \(debugLogEveryFrame)
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
    
    // Enforced trail fade parameters (cap trails to ~0.01 intensity by 3 seconds)
    private let trailMaxFadeSeconds: Double = 3.0
    private let trailFadeTargetResidual: Double = 0.01  // 1% remains at 3s
    
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
        
        // Important: always clear persistent GPU layers on the first frame of a new engine instance
        // so manual "Clear Preview" actually clears the Metal accumulation textures.
        forceClearOnNextFrame = true
        os_log("Engine init: will force clear on next frame to reset accumulation textures", log: log, type: .info)
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
        
        // Diagnostics toggles change doesn't require rebuilds, just update config.
        let diagnosticsChanged =
            config.debugDropBaseEveryNFrames != newConfig.debugDropBaseEveryNFrames ||
            config.debugForceClearEveryNFrames != newConfig.debugForceClearEveryNFrames ||
            config.debugLogEveryFrame != newConfig.debugLogEveryFrame
        if diagnosticsChanged {
            os_log("Diagnostics config changed: dropBaseEveryN=%{public}d, forceClearEveryN=%{public}d, logEveryFrame=%{public}@",
                   log: log, type: .info,
                   newConfig.debugDropBaseEveryNFrames,
                   newConfig.debugForceClearEveryNFrames,
                   newConfig.debugLogEveryFrame ? "true" : "false")
        }
        
        // If debug overlay visibility toggled, log it (no renderer rebuild needed anymore)
        let overlayChanged = (config.debugOverlayEnabled != newConfig.debugOverlayEnabled)
        if overlayChanged {
            os_log("Debug overlay toggled: %{public}@", log: log, type: .info, newConfig.debugOverlayEnabled ? "ENABLED" : "disabled")
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
    
    // MARK: - Trail decay enforcement (≤ 3s to ~1%)
    
    private func enforcedKeepFor(dt: CFTimeInterval) -> Float {
        // If no time passed, do not decay.
        guard dt > 0 else { return 1.0 }
        // Compute per-second keep so that keep^T = residual (e.g., 0.01 at 3s).
        let keepPerSecond = pow(trailFadeTargetResidual, 1.0 / trailMaxFadeSeconds)
        let keepForDt = pow(keepPerSecond, dt)
        return Float(keepForDt)
    }
    
    // MARK: - Frame Advancement (GPU path)
    
    func advanceFrameGPU() -> StarryDrawData {
        engineFrameIndex &+= 1

        // Optional periodic forced clears for diagnostics (only when debug overlay is enabled)
        if config.debugOverlayEnabled &&
            config.debugForceClearEveryNFrames > 0 &&
            (engineFrameIndex % UInt64(config.debugForceClearEveryNFrames) == 0) {
            forceClearOnNextFrame = true
            os_log("advanceFrameGPU: DIAG force clear scheduled for this frame (every N=%{public}d)", log: log, type: .info, config.debugForceClearEveryNFrames)
        }

        let logEveryFrame = config.debugOverlayEnabled || config.debugLogEveryFrame
        let logThisFrame = logEveryFrame || (verboseLogging && (engineFrameIndex % 50 == 0))
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

        // Honor a forced clear (e.g., config change or resize or diagnostics)
        if forceClearOnNextFrame {
            os_log("advanceFrameGPU: forceClearOnNextFrame active — will clear accumulation textures", log: log, type: .info)
            clearAll = true
            satellitesKeep = 0.0
            shootingKeep = 0.0
            forceClearOnNextFrame = false
        }

        // DIAGNOSTIC: Intentionally drop base sprites every N frames (only when debug overlay is enabled)
        if config.debugOverlayEnabled &&
            config.debugDropBaseEveryNFrames > 0 &&
            (engineFrameIndex % UInt64(config.debugDropBaseEveryNFrames) == 0) {
            let dropped = baseSprites.count
            baseSprites.removeAll()
            os_log("advanceFrameGPU: DIAG dropped all base sprites this frame (every N=%{public}d) — dropped=%{public}d",
                   log: log, type: .info, config.debugDropBaseEveryNFrames, dropped)
        }
        
        // Enforce fast trail fade (≤ 3s to ~1%)
        let enforcedKeep = enforcedKeepFor(dt: dt)
        if satellitesKeep > enforcedKeep {
            if logThisFrame {
                os_log("advanceFrameGPU: clamping satellitesKeep %{public}.3f -> %{public}.3f (≤3s fade)", log: log, type: .info, Double(satellitesKeep), Double(enforcedKeep))
            }
            satellitesKeep = enforcedKeep
        }
        if shootingKeep > enforcedKeep {
            if logThisFrame {
                os_log("advanceFrameGPU: clamping shootingKeep %{public}.3f -> %{public}.3f (≤3s fade)", log: log, type: .info, Double(shootingKeep), Double(enforcedKeep))
            }
            shootingKeep = enforcedKeep
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

        // Optional periodic forced clears for diagnostics (only when debug overlay is enabled)
        if config.debugOverlayEnabled &&
            config.debugForceClearEveryNFrames > 0 &&
            (engineFrameIndex % UInt64(config.debugForceClearEveryNFrames) == 0) {
            forceClearOnNextFrame = true
            os_log("advanceFrame(headless): DIAG force clear scheduled for this frame (every N=%{public}d)", log: log, type: .info, config.debugForceClearEveryNFrames)
        }

        let logEveryFrame = config.debugOverlayEnabled || config.debugLogEveryFrame
        let logThisFrame = logEveryFrame || (verboseLogging && (engineFrameIndex % 50 == 0))
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

        // Honor a forced clear (e.g., config change or resize or diagnostics)
        if forceClearOnNextFrame {
            os_log("advanceFrame(headless): forceClearOnNextFrame active — will clear accumulation textures", log: log, type: .info)
            clearAll = true
            satellitesKeep = 0.0
            shootingKeep = 0.0
            forceClearOnNextFrame = false
        }

        // DIAGNOSTIC: Intentionally drop base sprites every N frames (only when debug overlay is enabled)
        if config.debugOverlayEnabled &&
            config.debugDropBaseEveryNFrames > 0 &&
            (engineFrameIndex % UInt64(config.debugDropBaseEveryNFrames) == 0) {
            let dropped = baseSprites.count
            baseSprites.removeAll()
            os_log("advanceFrame(headless): DIAG dropped all base sprites this frame (every N=%{public}d) — dropped=%{public}d",
                   log: log, type: .info, config.debugDropBaseEveryNFrames, dropped)
        }
        
        // Enforce fast trail fade (≤ 3s to ~1%)
        let enforcedKeep = enforcedKeepFor(dt: dt)
        if satellitesKeep > enforcedKeep {
            if logThisFrame {
                os_log("advanceFrame(headless): clamping satellitesKeep %{public}.3f -> %{public}.3f (≤3s fade)", log: log, type: .info, Double(satellitesKeep), Double(enforcedKeep))
            }
            satellitesKeep = enforcedKeep
        }
        if shootingKeep > enforcedKeep {
            if logThisFrame {
                os_log("advanceFrame(headless): clamping shootingKeep %{public}.3f -> %{public}.3f (≤3s fade)", log: log, type: .info, Double(shootingKeep), Double(enforcedKeep))
            }
            shootingKeep = enforcedKeep
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
            os_log("Stats: FPS=%.1f CPU=%.1f%%", log: log, type: .debug, currentFPS, currentCPUPercent)
        }
    }
}
