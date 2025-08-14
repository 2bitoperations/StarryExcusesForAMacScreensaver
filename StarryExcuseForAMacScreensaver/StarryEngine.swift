import Foundation
import CoreGraphics
import os

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
    var traceEnabled: Bool
}

final class StarryEngine {
    private(set) var context: CGContext
    private let log: OSLog
    private(set) var config: StarryRuntimeConfig
    
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var size: CGSize
    private var lastInitSize: CGSize
    
    init(size: CGSize,
         log: OSLog,
         config: StarryRuntimeConfig) {
        self.size = size
        self.lastInitSize = size
        self.log = log
        self.config = config
        self.context = StarryEngine.makeContext(size: size)
        clear()
    }
    
    private static func makeContext(size: CGSize) -> CGContext {
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
    
    // Resize support (e.g. preview window size changes)
    func resizeIfNeeded(newSize: CGSize) {
        guard newSize != lastInitSize, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        lastInitSize = newSize
        context = StarryEngine.makeContext(size: size)
        skyline = nil
        skylineRenderer = nil
        clear()
    }
    
    // Update runtime (unsaved) configuration for preview, or after user saves for main view.
    func updateConfig(_ newConfig: StarryRuntimeConfig) {
        // Only rebuild if something material changed
        if config.starsPerUpdate != newConfig.starsPerUpdate ||
            config.buildingHeight != newConfig.buildingHeight ||
            config.moonTraversalMinutes != newConfig.moonTraversalMinutes ||
            config.moonMinRadius != newConfig.moonMinRadius ||
            config.moonMaxRadius != newConfig.moonMaxRadius ||
            config.moonBrightBrightness != newConfig.moonBrightBrightness ||
            config.moonDarkBrightness != newConfig.moonDarkBrightness {
            skyline = nil
            skylineRenderer = nil
        }
        config = newConfig
    }
    
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
                                  moonDarkBrightness: config.moonDarkBrightness)
            if let skyline = skyline {
                skylineRenderer = SkylineCoreRenderer(skyline: skyline,
                                                      log: log,
                                                      traceEnabled: config.traceEnabled)
            }
        } catch {
            os_log("StarryEngine: unable to init skyline %{public}@",
                   log: log, type: .fault, "\(error)")
        }
    }
    
    private func clear() {
        context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        context.fill(CGRect(origin: .zero, size: size))
    }
    
    // Advance one animation frame. Returns a CGImage snapshot of the framebuffer.
    @discardableResult
    func advanceFrame() -> CGImage? {
        ensureSkyline()
        guard let skyline = skyline,
              let _ = skylineRenderer else {
            return context.makeImage()
        }
        if skyline.shouldClearNow() {
            self.skyline = nil
            self.skylineRenderer = nil
            clear()
            ensureSkyline()
        }
        skylineRenderer?.drawSingleFrame(context: context)
        return context.makeImage()
    }
}
