import Foundation
import CoreGraphics
import os
import QuartzCore   // For CACurrentMediaTime()
import AppKit       // For font / color / attributed string drawing
import Darwin       // For task_info CPU sampling

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
    
    // Debug overlay (FPS / CPU / Time)
    var debugOverlayEnabled: Bool = false
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
    // Debug text overlay (transparent) rewritten each frame
    private var debugTextLayerContext: CGContext
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
    
    // FPS computation (smoothed)
    private var fpsAccumulatedTime: CFTimeInterval = 0
    private var fpsFrameCount: Int = 0
    private var currentFPS: Double = 0
    
    // CPU usage sampling
    private var lastProcessCPUTimesSeconds: Double = 0
    private var lastCPUSampleWallTime: CFTimeInterval = 0
    private var currentCPUPercent: Double = 0
    
    // Date formatter (ISO 8601, no fractional seconds, 24-hour)
    private let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
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
        self.debugTextLayerContext = StarryEngine.makeTransparentContext(size: size)
        self.compositeContext = StarryEngine.makeOpaqueContext(size: size)
        
        clearBase()
        clearSatellitesLayer(full: true)
        clearMoonLayer()
        clearShootingStarsLayer(full: true)
        clearDebugTextLayer()
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
        debugTextLayerContext = StarryEngine.makeTransparentContext(size: size)
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
        clearDebugTextLayer()
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
        
        let debugOverlayAffecting = config.debugOverlayEnabled != newConfig.debugOverlayEnabled
        if debugOverlayAffecting {
            clearDebugTextLayer()
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
    
    private func clearDebugTextLayer() {
        debugTextLayerContext.clear(CGRect(origin: .zero, size: size))
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
    
    // MARK: - Debug Overlay Rendering
    
    private func updateDebugOverlayLayer() {
        guard config.debugOverlayEnabled else { return }
        clearDebugTextLayer()
        
        let dateString = isoDateFormatter.string(from: Date())
        let text = String(format: "FPS: %.1f\nCPU: %.1f%%\nTime: %@", currentFPS, currentCPUPercent, dateString)
        
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.9),
            .paragraphStyle: paragraph
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrString.size()
        let padding: CGFloat = 6
        let rect = CGRect(x: size.width - textSize.width - padding,
                          y: size.height - textSize.height - padding,
                          width: textSize.width,
                          height: textSize.height)
        
        // Background box (rounded)
        let bgRect = rect.insetBy(dx: -4, dy: -3)
        debugTextLayerContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        let path = CGPath(roundedRect: bgRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        debugTextLayerContext.addPath(path)
        debugTextLayerContext.fillPath()
        
        // Flip coordinates for AppKit text drawing
        debugTextLayerContext.saveGState()
        debugTextLayerContext.translateBy(x: 0, y: size.height)
        debugTextLayerContext.scaleBy(x: 1, y: -1)
        // Because we've flipped, adjust Y
        let flippedRect = CGRect(x: rect.origin.x,
                                 y: size.height - rect.origin.y - rect.height,
                                 width: rect.width,
                                 height: rect.height)
        attrString.draw(in: flippedRect)
        debugTextLayerContext.restoreGState()
    }
    
    // MARK: - CPU Sampling
    
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
            // Fallback: don't update on error
            return
        }
        
        if lastProcessCPUTimesSeconds == 0 {
            lastProcessCPUTimesSeconds = cpuSeconds
            lastCPUSampleWallTime = CACurrentMediaTime()
            return
        }
        let deltaCPU = max(0, cpuSeconds - lastProcessCPUTimesSeconds)
        // Percent of a single core (Activity Monitor style)
        let percent = (deltaCPU / dt) * 100.0
        // Light smoothing (EMA)
        currentCPUPercent = currentCPUPercent * 0.8 + percent * 0.2
        lastProcessCPUTimesSeconds = cpuSeconds
        lastCPUSampleWallTime = CACurrentMediaTime()
    }
    
    // MARK: - FPS Update
    
    private func updateFPS(dt: CFTimeInterval) {
        fpsFrameCount += 1
        fpsAccumulatedTime += dt
        if fpsAccumulatedTime >= 0.5 {
            let fps = Double(fpsFrameCount) / fpsAccumulatedTime
            // Smooth with a little inertia
            currentFPS = currentFPS * 0.6 + fps * 0.4
            fpsAccumulatedTime = 0
            fpsFrameCount = 0
        }
    }
    
    // MARK: - Frame Advancement
    
    @discardableResult
    func advanceFrame() -> CGImage? {
        ensureSkyline()
        let now = CACurrentMediaTime()
        let dt = max(0.0, now - lastFrameTime)
        lastFrameTime = now
        
        updateFPS(dt: dt)
        sampleCPU(dt: dt)
        
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
            clearDebugTextLayer()
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
        
        // Debug overlay (after everything else)
        updateDebugOverlayLayer()
        
        // Composite order: base -> satellites -> shooting stars -> moon -> debug
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
        if config.debugOverlayEnabled,
           let debugImage = debugTextLayerContext.makeImage() {
            compositeContext.draw(debugImage, in: CGRect(origin: .zero, size: size))
        }
        
        return compositeContext.makeImage()
    }
}
