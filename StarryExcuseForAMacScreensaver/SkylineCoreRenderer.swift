import Foundation
import os
import CoreGraphics
import simd

// Renders ONLY the evolving star field, building lights, and flasher.
// Now emits GPU sprite instances instead of drawing into a CGContext.
// Refactored (2025): star spawning is purely time-based using starsPerSecond.
// Legacy "per update / per frame" star counts are no longer consulted.
class SkylineCoreRenderer {
    let skyline: Skyline
    let log: OSLog
    let starSize = 1
    let traceEnabled: Bool
    
    private var frameCounter: Int = 0

    // When true, do NOT emit the flasher sprite into the BaseLayer.
    // This prevents a moving/blinking dot from "baking" trails into the persistent base.
    private var disableFlasherOnBase: Bool = false
    
    // --- Time-based spawning state ---
    private var starsPerSecond: Double
    private var buildingLightsPerSecond: Double
    private var starAccumulator: Double = 0
    private var buildingLightAccumulator: Double = 0
    
    // Default density if caller passes <=0 (no legacy per-update fallback any more).
    private let defaultStarsPerSecond: Double = 800.0
    
    init(skyline: Skyline,
         log: OSLog,
         traceEnabled: Bool,
         disableFlasherOnBase: Bool,
         starsPerSecond: Double = 0,
         buildingLightsPerSecond: Double = 0) {
        self.skyline = skyline
        self.log = log
        self.traceEnabled = traceEnabled
        self.disableFlasherOnBase = disableFlasherOnBase
        
        // Stars: pure per-second model. Provide a reasonable default if unspecified.
        if starsPerSecond > 0 {
            self.starsPerSecond = starsPerSecond
        } else {
            self.starsPerSecond = defaultStarsPerSecond
        }
        
        // Building lights still support explicit per-second (existing optional legacy fallback preserved here).
        if buildingLightsPerSecond > 0 {
            self.buildingLightsPerSecond = buildingLightsPerSecond
        } else {
            // Keep legacy density heuristic for lights (derive from legacy per-update * assumed 10 FPS)
            self.buildingLightsPerSecond = Double(skyline.buildingLightsPerUpdate) * 10.0
        }
        
        if starsPerSecond <= 0 {
            os_log("SkylineCoreRenderer init: starsPerSecond unspecified -> default %.2f", log: log, type: .info, self.starsPerSecond)
        } else {
            os_log("SkylineCoreRenderer init: starsPerSecond=%.2f", log: log, type: .info, self.starsPerSecond)
        }
        os_log("SkylineCoreRenderer init: buildingLightsPerSecond=%.2f (legacy perUpdate=%d)",
               log: log, type: .info, self.buildingLightsPerSecond, skyline.buildingLightsPerUpdate)
    }
    
    // Update per-second rates. Passing <=0 leaves existing value unchanged (no reversion to any per-update logic).
    func updateRates(starsPerSecond: Double, buildingLightsPerSecond: Double) {
        var changed = false
        if starsPerSecond > 0 && self.starsPerSecond != starsPerSecond {
            os_log("SkylineCoreRenderer rate update: stars %.2f -> %.2f", log: log, type: .info, self.starsPerSecond, starsPerSecond)
            self.starsPerSecond = starsPerSecond
            changed = true
        }
        if buildingLightsPerSecond > 0 && self.buildingLightsPerSecond != buildingLightsPerSecond {
            os_log("SkylineCoreRenderer rate update: building lights %.2f -> %.2f", log: log, type: .info, self.buildingLightsPerSecond, buildingLightsPerSecond)
            self.buildingLightsPerSecond = buildingLightsPerSecond
            changed = true
        }
        if changed {
            // (Optionally) reset accumulators to avoid burst; here we keep remainder for smoothness.
        }
    }
    
    func resetFrameCounter() { frameCounter = 0 }

    func setDisableFlasherOnBase(_ disabled: Bool) {
        guard disabled != disableFlasherOnBase else { return }
        disableFlasherOnBase = disabled
        os_log("SkylineCoreRenderer: disableFlasherOnBase -> %{public}@", log: log, type: .info, disabled ? "true" : "false")
    }
    
    // Deep-reset hook (currently light weight; present for parity with Metal renderer memory release)
    func resetForMemoryRelease() {
        starAccumulator = 0
        buildingLightAccumulator = 0
        frameCounter = 0
        os_log("SkylineCoreRenderer: counters reset for memory release", log: log, type: .info)
    }
    
    // Expose current flasher vertical geometry so other layers (e.g. satellites) can adapt.
    // Returns (centerY, radius) in pixel coordinates or nil if no flasher.
    func currentFlasherInfo() -> (centerY: CGFloat, radius: CGFloat)? {
        guard let flasher = skyline.getFlasher() else { return nil }
        let cy = CGFloat(flasher.yPos)
        let r = CGFloat(skyline.flasherRadius)
        return (cy, r)
    }
    
    // Convenience: top edge Y of flasher (centerY - radius), or nil.
    func currentFlasherTopY() -> CGFloat? {
        guard let info = currentFlasherInfo() else { return nil }
        return info.centerY - info.radius
    }
    
    // Generate sprite instances for this frame using time-based spawning.
    // dtSeconds: simulation time elapsed since last frame.
    func generateSprites(dtSeconds: Double) -> [SpriteInstance] {
        frameCounter &+= 1
        
        // Determine spawn counts via accumulator method (fractional retention).
        let starsDesired = starsPerSecond * max(0, dtSeconds)
        starAccumulator += starsDesired
        let starSpawnCount = Int(floor(starAccumulator))
        starAccumulator -= Double(starSpawnCount)
        
        let lightsDesired = buildingLightsPerSecond * max(0, dtSeconds)
        buildingLightAccumulator += lightsDesired
        let buildingLightSpawnCount = Int(floor(buildingLightAccumulator))
        buildingLightAccumulator -= Double(buildingLightSpawnCount)
        
        if traceEnabled && (frameCounter <= 5 || frameCounter % 60 == 0) {
            os_log("generateSprites(dt=%.4f) starSpawn=%d(acc=%.3f) lightSpawn=%d(acc=%.3f) flasherDisabled=%{public}@",
                   log: log, type: .info,
                   dtSeconds,
                   starSpawnCount, starAccumulator,
                   buildingLightSpawnCount, buildingLightAccumulator,
                   disableFlasherOnBase ? "true" : "false")
        }
        
        var sprites: [SpriteInstance] = []
        let startCount = sprites.count
        appendStars(into: &sprites, count: starSpawnCount)
        let afterStars = sprites.count
        appendBuildingLights(into: &sprites, count: buildingLightSpawnCount)
        let afterLights = sprites.count
        if !disableFlasherOnBase {
            appendFlasher(into: &sprites)
        } else if traceEnabled && (frameCounter <= 5 || frameCounter % 60 == 0) {
            os_log("SkylineCoreRenderer: flasher suppressed this frame", log: log, type: .info)
        }
        if traceEnabled && (frameCounter <= 5 || frameCounter % 60 == 0) {
            os_log("SkylineCoreRenderer frame=%{public}d starsAdded=%{public}d lightsAdded=%{public}d flasherAdded=%{public}d total=%{public}d",
                   log: log, type: .info,
                   frameCounter,
                   afterStars - startCount,
                   afterLights - afterStars,
                   sprites.count - afterLights,
                   sprites.count)
        }
        return sprites
    }
    
    private func appendStars(into sprites: inout [SpriteInstance], count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            let star = skyline.getSingleStar()
            let cx = Float(star.xPos) + 0.5
            let cy = Float(star.yPos) + 0.5
            let half = SIMD2<Float>(repeating: 0.5)
            let color = premulRGBA(r: Float(star.color.red), g: Float(star.color.green), b: Float(star.color.blue), a: 1.0)
            sprites.append(SpriteInstance(centerPx: SIMD2<Float>(cx, cy), halfSizePx: half, colorPremul: color, shape: .rect))
        }
    }
    
    private func appendBuildingLights(into sprites: inout [SpriteInstance], count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            let light = skyline.getSingleBuildingPoint()
            let cx = Float(light.xPos) + 0.5
            let cy = Float(light.yPos) + 0.5
            let half = SIMD2<Float>(repeating: 0.5)
            let color = premulRGBA(r: Float(light.color.red), g: Float(light.color.green), b: Float(light.color.blue), a: 1.0)
            sprites.append(SpriteInstance(centerPx: SIMD2<Float>(cx, cy), halfSizePx: half, colorPremul: color, shape: .rect))
        }
    }
    
    private func appendFlasher(into sprites: inout [SpriteInstance]) {
        guard let flasher = skyline.getFlasher() else { return }
        let cx = Float(flasher.xPos)
        let cy = Float(flasher.yPos)
        let r = Float(skyline.flasherRadius)
        let color = premulRGBA(r: Float(flasher.color.red), g: Float(flasher.color.green), b: Float(flasher.color.blue), a: 1.0)
        sprites.append(SpriteInstance(centerPx: SIMD2<Float>(cx, cy),
                                      halfSizePx: SIMD2<Float>(r, r),
                                      colorPremul: color,
                                      shape: .circle))
        if traceEnabled && (frameCounter <= 5 || frameCounter % 60 == 0) {
            os_log("SkylineCoreRenderer flasher at (%.1f, %.1f) r=%.1f", log: log, type: .info, Double(cx), Double(cy), Double(r))
        }
    }
    
    // Store colors as premultiplied RGBA to match shader expectations.
    private func premulRGBA(r: Float, g: Float, b: Float, a: Float) -> SIMD4<Float> {
        return SIMD4<Float>(r * a, g * a, b * a, a)
    }
}
