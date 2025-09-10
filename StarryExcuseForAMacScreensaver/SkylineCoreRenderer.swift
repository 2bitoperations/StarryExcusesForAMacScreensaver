import Foundation
import os
import CoreGraphics
import simd

// Renders ONLY the evolving star field, building lights, and flasher.
// Now emits GPU sprite instances instead of drawing into a CGContext.
// Updated to support time-based spawning (per-second rates with fractional accumulation).
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
    private let legacyFallbackFPS: Double = 10.0
    
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
        
        // If caller passed 0 (unspecified), derive from legacy per-update values (assuming past 10 FPS cap).
        if starsPerSecond <= 0 {
            self.starsPerSecond = Double(skyline.starsPerUpdate) * legacyFallbackFPS
        } else {
            self.starsPerSecond = max(0, starsPerSecond)
        }
        if buildingLightsPerSecond <= 0 {
            self.buildingLightsPerSecond = Double(skyline.buildingLightsPerUpdate) * legacyFallbackFPS
        } else {
            self.buildingLightsPerSecond = max(0, buildingLightsPerSecond)
        }
        
        os_log("SkylineCoreRenderer init: starsPerSecond=%.2f buildingLightsPerSecond=%.2f (legacy perUpdate stars=%d lights=%d)",
               log: log, type: .info,
               self.starsPerSecond, self.buildingLightsPerSecond,
               skyline.starsPerUpdate, skyline.buildingLightsPerUpdate)
    }
    
    func updateRates(starsPerSecond: Double, buildingLightsPerSecond: Double) {
        let newStars = starsPerSecond > 0 ? starsPerSecond : Double(skyline.starsPerUpdate) * legacyFallbackFPS
        let newLights = buildingLightsPerSecond > 0 ? buildingLightsPerSecond : Double(skyline.buildingLightsPerUpdate) * legacyFallbackFPS
        if self.starsPerSecond != newStars || self.buildingLightsPerSecond != newLights {
            os_log("SkylineCoreRenderer rate update: stars %.2f -> %.2f | lights %.2f -> %.2f",
                   log: log, type: .info,
                   self.starsPerSecond, newStars,
                   self.buildingLightsPerSecond, newLights)
        }
        self.starsPerSecond = max(0, newStars)
        self.buildingLightsPerSecond = max(0, newLights)
    }
    
    func resetFrameCounter() { frameCounter = 0 }

    func setDisableFlasherOnBase(_ disabled: Bool) {
        guard disabled != disableFlasherOnBase else { return }
        disableFlasherOnBase = disabled
        os_log("SkylineCoreRenderer: disableFlasherOnBase -> %{public}@", log: log, type: .info, disabled ? "true" : "false")
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
