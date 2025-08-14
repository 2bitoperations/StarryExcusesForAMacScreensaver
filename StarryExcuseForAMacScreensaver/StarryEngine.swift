import Foundation
import CoreGraphics
import os
import QuartzCore   // For CACurrentMediaTime()

// Encapsulates the rendering state and logic so both the main ScreenSaverView
// and the configuration sheet preview can share the exact same code path.
struct StarryRuntimeConfig {
    var starsPerUpdate: Int
    var buildingHeight: Double
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
    // Troubleshooting: show the crescent clip region (bright or dark minority) in red
    var showCrescentClipMask: Bool
}

final class StarryEngine {
    // Base (persistent) star/building/backdrop context
    private(set) var baseContext: CGContext
    // Moon overlay (transparent) updated at most once per second
    private var moonLayerContext: CGContext
    // Temporary compositing context (reused) used to produce final frame
    private var compositeContext: CGContext
    
    private let log: OSLog
    private(set) var config: StarryRuntimeConfig
    
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var moonRenderer: MoonLayerRenderer?
    
    private var size: CGSize
    private var lastInitSize: CGSize
    
    private var lastMoonRenderTime: TimeInterval = 0 // monotonic time
    
    init(size: CGSize,
         log: OSLog,
         config: StarryRuntimeConfig) {
        self.size = size
        self.lastInitSize = size
        self.log = log
        self.config = config
        
        self.baseContext = StarryEngine.makeOpaqueContext(size: size)
        self.moonLayerContext = StarryEngine.makeTransparentContext(size: size)
        self.compositeContext = StarryEngine.makeOpaqueContext(size: size)
        
        clearBase()
        clearMoonLayer()
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
        moonLayerContext = StarryEngine.makeTransparentContext(size: size)
        compositeContext = StarryEngine.makeOpaqueContext(size: size)
        
        skyline = nil
        skylineRenderer = nil
        moonRenderer = nil
        clearBase()
        clearMoonLayer()
    }
    
    // MARK: - Configuration
    
    func updateConfig(_ newConfig: StarryRuntimeConfig) {
        if config.starsPerUpdate != newConfig.starsPerUpdate ||
            config.buildingHeight != newConfig.buildingHeight ||
            config.moonTraversalMinutes != newConfig.moonTraversalMinutes ||
            config.moonMinRadius != newConfig.moonMinRadius ||
            config.moonMaxRadius != newConfig.moonMaxRadius ||
            config.moonBrightBrightness != newConfig.moonBrightBrightness ||
            config.moonDarkBrightness != newConfig.moonDarkBrightness ||
            config.moonPhaseOverrideEnabled != newConfig.moonPhaseOverrideEnabled ||
            config.moonPhaseOverrideValue != newConfig.moonPhaseOverrideValue ||
            config.showCrescentClipMask != newConfig.showCrescentClipMask {
            skyline = nil
            skylineRenderer = nil
            moonRenderer = nil
        }
        config = newConfig
    }
    
    // MARK: - Initialization of Skyline & Moon
    
    private func ensureSkyline() {
        guard skyline == nil || skylineRenderer == nil else { return }
        do {
            let traversalSeconds = Double(config.moonTraversalMinutes) * 60.0
            skyline = try Skyline(screenXMax: Int(size.width),
                                  screenYMax: Int(size.height),
                                  buildingHeightPercentMax: config.buildingHeight,
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
                                                 showCrescentClipMask: config.showCrescentClipMask)
                // force first moon render immediately
                lastMoonRenderTime = 0
            }
        } catch {
            os_log("StarryEngine: unable to init skyline %{public}@", log: log, type: .fault, "\(error)")
        }
    }
    
    // MARK: - Clearing
    
    private func clearBase() {
        baseContext.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        baseContext.fill(CGRect(origin: .zero, size: size))
    }
    
    private func clearMoonLayer() {
        moonLayerContext.clear(CGRect(origin: .zero, size: size))
    }
    
    // MARK: - Moon Rendering Rate Limiting
    
    private func maybeUpdateMoonLayer() {
        guard let renderer = moonRenderer else { return }
        let now = CACurrentMediaTime()
        // Update at most once per second
        if now - lastMoonRenderTime < 1.0 { return }
        lastMoonRenderTime = now
        clearMoonLayer()
        renderer.renderMoon(into: moonLayerContext)
    }
    
    // MARK: - Frame Advancement
    
    @discardableResult
    func advanceFrame() -> CGImage? {
        ensureSkyline()
        guard let skyline = skyline,
              let skylineRenderer = skylineRenderer else {
            return baseContext.makeImage()
        }
        
        if skyline.shouldClearNow() {
            skylineRenderer.resetFrameCounter()
            clearBase()
            clearMoonLayer()
            self.skyline = nil
            self.skylineRenderer = nil
            self.moonRenderer = nil
            ensureSkyline()
            return baseContext.makeImage()
        }
        
        // Draw incremental stars/building lights/flasher onto base (persistent)
        skylineRenderer.drawSingleFrame(context: baseContext)
        
        // Possibly update moon layer (overlay not baked into base)
        maybeUpdateMoonLayer()
        
        // Composite: base first, then moon overlay
        compositeContext.setFillColor(CGColor(gray: 0, alpha: 1))
        compositeContext.fill(CGRect(origin: .zero, size: size))
        if let baseImage = baseContext.makeImage() {
            compositeContext.draw(baseImage, in: CGRect(origin: .zero, size: size))
        }
        if let moonImage = moonLayerContext.makeImage() {
            compositeContext.draw(moonImage, in: CGRect(origin: .zero, size: size))
        }
        
        return compositeContext.makeImage()
    }
}
