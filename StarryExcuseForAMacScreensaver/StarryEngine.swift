import Foundation
import CoreGraphics
import os
import QuartzCore   // For CACurrentMediaTime()
import CoreText     // Core Text for text layout/drawing
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
    // Base (persistent) star/building/backdrop context
    private(set) var baseContext: CGContext
    // Satellites layer (transparent, rewritten each frame, optional trail)
    private var satellitesLayerContext: CGContext
    // Shooting stars layer (transparent, accumulation + decay)
    private var shootingStarsLayerContext: CGContext
    // Moon overlay (transparent) rewritten only when needed
    private var moonLayerContext: CGContext
    // Debug text overlay (transparent) rewritten when text changes
    private var debugTextLayerContext: CGContext
    // Temporary compositing context (reused) used to produce final frame
    private var compositeContext: CGContext
    
    // Cached CGImages for layers (avoid makeImage calls when unchanged)
    private var baseImage: CGImage?
    private var satellitesImage: CGImage?
    private var shootingStarsImage: CGImage?
    private var moonImage: CGImage?
    private var debugImage: CGImage?
    
    // Dirty flags (set true when context content changed and new CGImage needed)
    private var satellitesDirty = true
    private var shootingStarsDirty = true
    private var moonDirty = true
    private var debugDirty = true
    
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
    
    // Debug overlay state
    private let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let debugFont: CTFont = CTFontCreateWithName("Menlo" as CFString, 12, nil)
    private lazy var debugBaseAttributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): debugFont,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 0.9)
    ]
    private var lastDebugOverlayString: String = ""
    
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
        
        // Log full configuration on engine startup for diagnostics
        os_log("StarryEngine initialized with config:\n%{public}@",
               log: log, type: .info, config.description)
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
        
        // Everything needs fresh images
        satellitesDirty = true
        shootingStarsDirty = true
        moonDirty = true
        debugDirty = true
        baseImage = nil
        satellitesImage = nil
        shootingStarsImage = nil
        moonImage = nil
        debugImage = nil
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
            moonDirty = true
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
            shootingStarsDirty = true
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
            satellitesDirty = true
        }
        
        let debugOverlayAffecting = config.debugOverlayEnabled != newConfig.debugOverlayEnabled
        if debugOverlayAffecting {
            clearDebugTextLayer()
            debugDirty = true
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
                moonDirty = true
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
        shootingStarsDirty = true
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
        satellitesDirty = true
    }
    
    // MARK: - Clearing
    
    private func clearBase() {
        baseContext.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        baseContext.fill(CGRect(origin: .zero, size: size))
        baseImage = nil
    }
    
    private func clearMoonLayer() {
        moonLayerContext.clear(CGRect(origin: .zero, size: size))
        moonImage = nil
        moonDirty = true
    }
    
    private func clearShootingStarsLayer(full: Bool) {
        shootingStarsLayerContext.clear(CGRect(origin: .zero, size: size))
        if full {
            shootingStarsRenderer?.reset()
        }
        shootingStarsImage = nil
        shootingStarsDirty = true
    }
    
    private func clearSatellitesLayer(full: Bool) {
        if config.satellitesTrailing {
            // Fade instead of full clear when trailing, unless full requested
            if full {
                satellitesLayerContext.clear(CGRect(origin: .zero, size: size))
            } else {
                let decay = config.satellitesTrailDecay
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
        satellitesImage = nil
        satellitesDirty = true
    }
    
    private func clearDebugTextLayer() {
        debugTextLayerContext.clear(CGRect(origin: .zero, size: size))
        debugImage = nil
        debugDirty = true
        lastDebugOverlayString = ""
    }
    
    // MARK: - Moon Rendering
    
    // Returns true if moon layer content changed
    private func updateMoonLayer() -> Bool {
        guard let renderer = moonRenderer else { return false }
        let did = renderer.renderMoon(into: moonLayerContext)
        if did { moonDirty = true }
        return did
    }
    
    // MARK: - Shooting Stars Rendering
    
    private func updateShootingStarsLayer(dt: CFTimeInterval) {
        guard config.shootingStarsEnabled,
              let renderer = shootingStarsRenderer else { return }
        renderer.update(into: shootingStarsLayerContext, dt: dt)
        shootingStarsDirty = true
    }
    
    // MARK: - Satellites Rendering
    
    private func updateSatellitesLayer(dt: CFTimeInterval) {
        guard config.satellitesEnabled,
              let renderer = satellitesRenderer else { return }
        renderer.update(into: satellitesLayerContext, dt: dt)
        satellitesDirty = true
    }
    
    // MARK: - Debug Overlay Rendering (Core Text)
    
    // Returns true if text changed (and was redrawn)
    private func updateDebugOverlayLayer() -> Bool {
        guard config.debugOverlayEnabled else { return false }
        
        let dateString = isoDateFormatter.string(from: Date())
        let newText = String(format: "FPS: %.1f\nCPU: %.1f%%\nTime: %@", currentFPS, currentCPUPercent, dateString)
        if newText == lastDebugOverlayString {
            return false // unchanged -> no redraw or new image needed
        }
        lastDebugOverlayString = newText
        debugDirty = true
        clearDebugTextLayer()
        
        let lines = newText.components(separatedBy: "\n")
        
        // Metrics
        let ascent = CTFontGetAscent(debugFont)
        let descent = CTFontGetDescent(debugFont)
        let leading = CTFontGetLeading(debugFont)
        let lineAdvance = ascent + descent + max(leading, 2)
        
        var lineCTObjects: [CTLine] = []
        var maxLineWidth: CGFloat = 0
        for l in lines {
            let attr = NSAttributedString(string: l, attributes: debugBaseAttributes)
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            if width > maxLineWidth { maxLineWidth = width }
            lineCTObjects.append(ctLine)
        }
        
        let totalHeight = lineAdvance * CGFloat(lines.count)
        let padding: CGFloat = 6
        let rect = CGRect(
            x: size.width - maxLineWidth - padding,
            y: size.height - totalHeight - padding,
            width: maxLineWidth,
            height: totalHeight
        )
        
        let bgRect = rect.insetBy(dx: -4, dy: -3)
        debugTextLayerContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        let path = CGPath(roundedRect: bgRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        debugTextLayerContext.addPath(path)
        debugTextLayerContext.fillPath()
        
        var baselineY = rect.maxY - ascent
        for line in lineCTObjects {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let lineX = rect.maxX - lineWidth
            debugTextLayerContext.textPosition = CGPoint(x: lineX, y: baselineY)
            CTLineDraw(line, debugTextLayerContext)
            baselineY -= lineAdvance
        }
        return true
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
    
    // MARK: - FPS Update
    
    private func updateFPS(dt: CFTimeInterval) {
        fpsFrameCount += 1
        fpsAccumulatedTime += dt
        if fpsAccumulatedTime >= 0.5 {
            let fps = Double(fpsFrameCount) / fpsAccumulatedTime
            currentFPS = currentFPS * 0.6 + fps * 0.4
            fpsAccumulatedTime = 0
            fpsFrameCount = 0
            debugDirty = true // text will change when FPS updates
        }
    }
    
    // MARK: - Frame Advancement (CoreGraphics path)
    
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
            // Base only (first frame)
            baseImage = baseContext.makeImage()
            compositeContext.draw(baseImage!, in: CGRect(origin: .zero, size: size))
            return compositeContext.makeImage()
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
            baseImage = baseContext.makeImage()
            compositeContext.draw(baseImage!, in: CGRect(origin: .zero, size: size))
            return compositeContext.makeImage()
        }
        
        // Persistent stars/buildings/flasher (always changes base each frame)
        skylineRenderer.drawSingleFrame(context: baseContext)
        baseImage = baseContext.makeImage()
        
        // Satellites
        if config.satellitesEnabled {
            updateSatellitesLayer(dt: dt)
            if satellitesDirty {
                satellitesImage = satellitesLayerContext.makeImage()
                satellitesDirty = false
            }
        } else {
            satellitesImage = nil
        }
        
        // Shooting stars
        if config.shootingStarsEnabled {
            updateShootingStarsLayer(dt: dt)
            if shootingStarsDirty {
                shootingStarsImage = shootingStarsLayerContext.makeImage()
                shootingStarsDirty = false
            }
        } else {
            shootingStarsImage = nil
        }
        
        // Moon (only re-render if needed)
        if updateMoonLayer(), moonDirty {
            moonImage = moonLayerContext.makeImage()
            moonDirty = false
        } else if moonImage == nil, moonRenderer != nil {
            if updateMoonLayer() {
                moonImage = moonLayerContext.makeImage()
                moonDirty = false
            }
        }
        
        // Debug overlay
        if config.debugOverlayEnabled {
            if updateDebugOverlayLayer(), debugDirty {
                debugImage = debugTextLayerContext.makeImage()
                debugDirty = false
            }
        } else {
            debugImage = nil
        }
        
        // Composite order: base -> satellites -> shooting stars -> moon -> debug
        if let baseImage = baseImage {
            compositeContext.draw(baseImage, in: CGRect(origin: .zero, size: size))
        }
        if config.satellitesEnabled, let satImg = satellitesImage {
            compositeContext.draw(satImg, in: CGRect(origin: .zero, size: size))
        }
        if config.shootingStarsEnabled, let ssImg = shootingStarsImage {
            compositeContext.draw(ssImg, in: CGRect(origin: .zero, size: size))
        }
        if let moonImg = moonImage {
            compositeContext.draw(moonImg, in: CGRect(origin: .zero, size: size))
        }
        if config.debugOverlayEnabled, let dbgImg = debugImage {
            compositeContext.draw(dbgImg, in: CGRect(origin: .zero, size: size))
        }
        
        return compositeContext.makeImage()
    }
    
    // MARK: - Frame Advancement (Metal path, no CoreGraphics compositing)
    
    /// Advance simulation & per-layer CPU rendering, returning contexts + dirty flags for Metal upload.
    /// This skips CGImage creation and composite blending.
    func advanceFrameForMetal() -> StarryMetalFrameUpdate {
        ensureSkyline()
        let now = CACurrentMediaTime()
        let dt = max(0.0, now - lastFrameTime)
        lastFrameTime = now
        
        updateFPS(dt: dt)
        sampleCPU(dt: dt)
        
        // First frame (skyline not yet ready)
        guard let skyline = skyline,
              let skylineRenderer = skylineRenderer else {
            return StarryMetalFrameUpdate(
                size: size,
                baseContext: baseContext,
                satellitesContext: nil,
                satellitesChanged: false,
                shootingStarsContext: nil,
                shootingStarsChanged: false,
                moonContext: nil,
                moonChanged: false,
                debugContext: nil,
                debugChanged: false
            )
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
            return StarryMetalFrameUpdate(
                size: size,
                baseContext: baseContext,
                satellitesContext: nil,
                satellitesChanged: true,
                shootingStarsContext: nil,
                shootingStarsChanged: true,
                moonContext: nil,
                moonChanged: true,
                debugContext: nil,
                debugChanged: true
            )
        }
        
        // Base (always mutated)
        skylineRenderer.drawSingleFrame(context: baseContext)
        
        // Satellites
        var satellitesChangedOut = false
        if config.satellitesEnabled {
            updateSatellitesLayer(dt: dt)
            satellitesChangedOut = satellitesDirty
            satellitesDirty = false
        } else {
            satellitesChangedOut = satellitesDirty
            satellitesDirty = false
        }
        
        // Shooting stars
        var shootingStarsChangedOut = false
        if config.shootingStarsEnabled {
            updateShootingStarsLayer(dt: dt)
            shootingStarsChangedOut = shootingStarsDirty
            shootingStarsDirty = false
        } else {
            shootingStarsChangedOut = shootingStarsDirty
            shootingStarsDirty = false
        }
        
        // Moon
        var moonChangedOut = false
        if updateMoonLayer(), moonDirty {
            moonChangedOut = true
            moonDirty = false
        } else if moonRenderer != nil, moonImage == nil {
            if updateMoonLayer() {
                moonChangedOut = true
                moonDirty = false
            }
        }
        
        // Debug overlay
        var debugChangedOut = false
        if config.debugOverlayEnabled {
            if updateDebugOverlayLayer(), debugDirty {
                debugChangedOut = true
                debugDirty = false
            }
        } else if debugDirty {
            debugChangedOut = true
            debugDirty = false
        }
        
        return StarryMetalFrameUpdate(
            size: size,
            baseContext: baseContext,
            satellitesContext: config.satellitesEnabled ? satellitesLayerContext : nil,
            satellitesChanged: satellitesChangedOut,
            shootingStarsContext: config.shootingStarsEnabled ? shootingStarsLayerContext : nil,
            shootingStarsChanged: shootingStarsChangedOut,
            moonContext: moonRenderer != nil ? moonLayerContext : nil,
            moonChanged: moonChangedOut,
            debugContext: config.debugOverlayEnabled ? debugTextLayerContext : nil,
            debugChanged: debugChangedOut
        )
    }
}
