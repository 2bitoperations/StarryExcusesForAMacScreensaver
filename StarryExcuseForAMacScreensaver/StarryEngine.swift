import Foundation
import CoreGraphics
import os
import QuartzCore   // For CACurrentMediaTime()

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
    // These are small bright moving points crossing the sky similar to classic After Dark.
    // Defaults chosen for frequent spawning for initial testing.
    var satellitesEnabled: Bool = true
    // Average seconds between spawns (Poisson). 0.75 -> >1 per second on average.
    var satellitesAvgSpawnSeconds: Double = 0.75
    // Pixels per second of horizontal travel.
    var satellitesSpeed: Double = 90.0
    // Satellite rendered size (square / dot) in pixels.
    var satellitesSize: Double = 2.0
    // Brightness (0-1) multiplied into white.
    var satellitesBrightness: Double = 0.9
    // Allow a faint short trailing effect (simple alpha fade of previous frame).
    var satellitesTrailing: Bool = true
    // Trail decay factor per second (only if trailing enabled). 0.0 -> immediate clear, 1.0 -> no decay.
    var satellitesTrailDecay: Double = 0.80
}

final class StarryEngine {
    // Base (persistent) star/building/backdrop context
    private(set) var baseContext: CGContext
    // Satellites layer (transparent, rewritten each frame, optional trail)
    private var satellitesLayerContext: CGContext
    // Shooting stars layer (transparent, accumulation + decay)
    private var shootingStarsLayerContext: CGContext
    // Moon overlay (transparent) rewritten each frame (content internally cached)
    private var moonLayerContext: CGContext
    // Temporary compositing context (reused) used to produce final frame
    private var compositeContext: CGContext
    
    private let log: OSLog
    private(set) var config: StarryRuntimeConfig
    
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var moonRenderer: MoonLayerRenderer?
    private var shootingStarsRenderer: ShootingStarsLayerRenderer?
    private var satellitesRenderer: SatellitesLayerRenderer?
    
    private var size: CGSize
    private var lastInitSize: CGSize
    
    // Timing
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    
    init(size: CGSize,
         log: OSLog,
         config: StarryRuntimeConfig) {
        self.size = size
        self.lastInitSize = size
        self.log = log
        self.config = config
        
        self.baseContext = StarryEngine.makeOpaqueContext(size: size)
        self.satellitesLayerContext = StarryEngine.makeTransparentContext(size: size)
        self.shootingStarsLayerContext = StarryEngine.makeTransparentContext(size: size)
        self.moonLayerContext = StarryEngine.makeTransparentContext(size: size)
        self.compositeContext = StarryEngine.makeOpaqueContext(size: size)
        
        clearBase()
        clearSatellitesLayer(full: true)
        clearMoonLayer()
        clearShootingStarsLayer(full: true)
    }
    
    // MARK: - Context Helpers
    
    private static func makeOpaqueContext(size: CGSize) -> CGContext {
        let ctx = CGContext(data: nil,
                            width: Int(size.width),
                            height: Int(size.height),
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.interpolationQuality = .high
        return ctx
    }
    
    private static func makeTransparentContext(size: CGSize) -> CGContext {
        let ctx = CGContext(data: nil,
                            width: Int(size.width),
                            height: Int(size.height),
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setBlendMode(.normal)
        return ctx
    }
    
    // MARK: - Resizing
    
    func resizeIfNeeded(newSize: CGSize) {
        guard newSize != lastInitSize, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        lastInitSize = newSize
        
        baseContext = StarryEngine.makeOpaqueContext(size: size)
        satellitesLayerContext = StarryEngine.makeTransparentContext(size: size)
        shootingStarsLayerContext = StarryEngine.makeTransparentContext(size: size)
        moonLayerContext = StarryEngine.makeTransparentContext(size: size)
        compositeContext = StarryEngine.makeOpaqueContext(size: size)
        
        skyline = nil
        skylineRenderer = nil
        moonRenderer = nil
        shootingStarsRenderer = nil
        satellitesRenderer = nil
        clearBase()
        clearSatellitesLayer(full: true)
        clearMoonLayer()
        clearShootingStarsLayer(full: true)
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
            skyline = nil
            skylineRenderer = nil
            moonRenderer = nil
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
            shootingStarsRenderer = nil
            clearShootingStarsLayer(full: true)
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
            satellitesRenderer = nil
            clearSatellitesLayer(full: true)
        }
        
        config = newConfig
    }
    
    // MARK: - Initialization of Skyline & Moon & Shooting Stars & Satellites
    
    private func ensureSkyline() {
        guard skyline == nil || skylineRenderer == nil else {
            ensureSatellitesRenderer()
            ensureShootingStarsRenderer()
            return
        }
        do {
            let traversalSeconds = Double(config.moonTraversalMinutes) * 60.0
            skyline = try Skyline(screenXMax: Int(size.width),
                                  screenYMax: Int(size.height),
                                  buildingHeightPercentMax: config.buildingHeight,
                                  buildingFrequency: config.buildingFrequency,
                                  starsPerUpdate: config.starsPerUpdate,
                                  log: log,
                                  clearAfterDuration: config.secsBetweenClears,
                                  traceEnabled: config.traceEnabled,
                                  moonTraversalSeconds: traversalSeconds,
                                  moonBrightBrightness: config.moonBrightBrightness,
                                  moonDarkBrightness: config.moonDarkBrightness,
                                  moonDiameterScreenWidthPercent: config.moonDiameterScreenWidthPercent,
                                  moonPhaseOverrideEnabled: config.moonPhaseOverrideEnabled,
                                  moonPhaseOverrideValue: config.moonPhaseOverrideValue)
            if let skyline = skyline {
                skylineRenderer = SkylineCoreRenderer(skyline: skyline,
                                                      log: log,
                                                      traceEnabled: config.traceEnabled)
                moonRenderer = MoonLayerRenderer(skyline: skyline,
                                                 log: log,
                                                 brightBrightness: CGFloat(config.moonBrightBrightness),
                                                 darkBrightness: CGFloat(config.moonDarkBrightness),
                                                 showLightAreaTextureFillMask: config.showLightAreaTextureFillMask)
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
    }
    
    // MARK: - Clearing
    
    private func clearBase() {
        baseContext.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        baseContext.fill(CGRect(origin: .zero, size: size))
    }
    
    private func clearMoonLayer() {
        moonLayerContext.clear(CGRect(origin: .zero, size: size))
    }
    
    private func clearShootingStarsLayer(full: Bool) {
        shootingStarsLayerContext.clear(CGRect(origin: .zero, size: size))
        if full {
            shootingStarsRenderer?.reset()
        }
    }
    
    private func clearSatellitesLayer(full: Bool) {
        if config.satellitesTrailing {
            // Fade instead of full clear when trailing, unless full requested
            if full {
                satellitesLayerContext.clear(CGRect(origin: .zero, size: size))
            } else {
                let decay = pow((1.0 - (1.0 - config.satellitesTrailDecay)), 1.0) // already applied in renderer; keep hard clear optional
                satellitesLayerContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(1.0 - decay)))
                satellitesLayerContext.setBlendMode(.destinationOut)
                satellitesLayerContext.fill(CGRect(origin: .zero, size: size))
                satellitesLayerContext.setBlendMode(.normal)
            }
        } else {
            satellitesLayerContext.clear(CGRect(origin: .zero, size: size))
        }
        if full {
            satellitesRenderer?.reset()
        }
    }
    
    // MARK: - Moon Rendering
    
    private func updateMoonLayer() {
        guard let renderer = moonRenderer else { return }
        clearMoonLayer()
        renderer.renderMoon(into: moonLayerContext)
    }
    
    // MARK: - Shooting Stars Rendering
    
    private func updateShootingStarsLayer(dt: CFTimeInterval) {
        guard config.shootingStarsEnabled,
              let renderer = shootingStarsRenderer else { return }
        renderer.update(into: shootingStarsLayerContext, dt: dt)
    }
    
    // MARK: - Satellites Rendering
    
    private func updateSatellitesLayer(dt: CFTimeInterval) {
        guard config.satellitesEnabled,
              let renderer = satellitesRenderer else { return }
        renderer.update(into: satellitesLayerContext, dt: dt)
    }
    
    // MARK: - Frame Advancement
    
    @discardableResult
    func advanceFrame() -> CGImage? {
        ensureSkyline()
        let now = CACurrentMediaTime()
        let dt = max(0.0, now - lastFrameTime)
        lastFrameTime = now
        
        guard let skyline = skyline,
              let skylineRenderer = skylineRenderer else {
            return baseContext.makeImage()
        }
        
        if skyline.shouldClearNow() {
            skylineRenderer.resetFrameCounter()
            clearBase()
            clearSatellitesLayer(full: true)
            clearMoonLayer()
            clearShootingStarsLayer(full: true)
            self.skyline = nil
            self.skylineRenderer = nil
            self.moonRenderer = nil
            self.shootingStarsRenderer = nil
            self.satellitesRenderer = nil
            ensureSkyline()
            return baseContext.makeImage()
        }
        
        // Persistent stars/buildings/flasher
        skylineRenderer.drawSingleFrame(context: baseContext)
        
        // Satellites (clears/fades then draws)
        updateSatellitesLayer(dt: dt)
        
        // Shooting stars (accumulation + decay)
        updateShootingStarsLayer(dt: dt)
        
        // Moon
        updateMoonLayer()
        
        // Composite order: base -> satellites -> shooting stars -> moon
        compositeContext.setFillColor(CGColor(gray: 0, alpha: 1))
        compositeContext.fill(CGRect(origin: .zero, size: size))
        if let baseImage = baseContext.makeImage() {
            compositeContext.draw(baseImage, in: CGRect(origin: .zero, size: size))
        }
        if config.satellitesEnabled,
           let satellitesImage = satellitesLayerContext.makeImage() {
            compositeContext.draw(satellitesImage, in: CGRect(origin: .zero, size: size))
        }
        if config.shootingStarsEnabled,
           let shootingStarsImage = shootingStarsLayerContext.makeImage() {
            compositeContext.draw(shootingStarsImage, in: CGRect(origin: .zero, size: size))
        }
        if let moonImage = moonLayerContext.makeImage() {
            compositeContext.draw(moonImage, in: CGRect(origin: .zero, size: size))
        }
        
        return compositeContext.makeImage()
    }
}
