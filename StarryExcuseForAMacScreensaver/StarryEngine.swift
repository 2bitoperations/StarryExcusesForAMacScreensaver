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
    var moonMinRadius: Int
    var moonMaxRadius: Int
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
}

final class StarryEngine {
    // Base (persistent) star/building/backdrop context
    private(set) var baseContext: CGContext
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
        self.shootingStarsLayerContext = StarryEngine.makeTransparentContext(size: size)
        self.moonLayerContext = StarryEngine.makeTransparentContext(size: size)
        self.compositeContext = StarryEngine.makeOpaqueContext(size: size)
        
        clearBase()
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
        shootingStarsLayerContext = StarryEngine.makeTransparentContext(size: size)
        moonLayerContext = StarryEngine.makeTransparentContext(size: size)
        compositeContext = StarryEngine.makeOpaqueContext(size: size)
        
        skyline = nil
        skylineRenderer = nil
        moonRenderer = nil
        shootingStarsRenderer = nil
        clearBase()
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
            config.moonMinRadius != newConfig.moonMinRadius ||
            config.moonMaxRadius != newConfig.moonMaxRadius ||
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
        
        config = newConfig
    }
    
    // MARK: - Initialization of Skyline & Moon & Shooting Stars
    
    private func ensureSkyline() {
        guard skyline == nil || skylineRenderer == nil else {
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
                                  moonMinRadius: config.moonMinRadius,
                                  moonMaxRadius: config.moonMaxRadius,
                                  moonBrightBrightness: config.moonBrightBrightness,
                                  moonDarkBrightness: config.moonDarkBrightness,
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
            clearMoonLayer()
            clearShootingStarsLayer(full: true)
            self.skyline = nil
            self.skylineRenderer = nil
            self.moonRenderer = nil
            self.shootingStarsRenderer = nil
            ensureSkyline()
            return baseContext.makeImage()
        }
        
        // Persistent stars/buildings/flasher
        skylineRenderer.drawSingleFrame(context: baseContext)
        
        // Shooting stars (accumulation + decay)
        updateShootingStarsLayer(dt: dt)
        
        // Moon
        updateMoonLayer()
        
        // Composite order: base -> shooting stars -> moon
        compositeContext.setFillColor(CGColor(gray: 0, alpha: 1))
        compositeContext.fill(CGRect(origin: .zero, size: size))
        if let baseImage = baseContext.makeImage() {
            compositeContext.draw(baseImage, in: CGRect(origin: .zero, size: size))
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
