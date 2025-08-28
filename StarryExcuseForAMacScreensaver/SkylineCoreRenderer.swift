//
//  SkylineCoreRenderer.swift
//  StarryExcuseForAMacScreensaver
//

import Foundation
import os
import CoreGraphics
import simd

// Renders ONLY the evolving star field, building lights, and flasher.
// Now emits GPU sprite instances instead of drawing into a CGContext.
class SkylineCoreRenderer {
    let skyline: Skyline
    let log: OSLog
    let starSize = 1
    let traceEnabled: Bool
    
    private var frameCounter: Int = 0

    // When true, do NOT emit the flasher sprite into the BaseLayer.
    // This prevents a moving/blinking dot from "baking" trails into the persistent base.
    private var disableFlasherOnBase: Bool = false
    
    init(skyline: Skyline, log: OSLog, traceEnabled: Bool, disableFlasherOnBase: Bool) {
        self.skyline = skyline
        self.log = log
        self.traceEnabled = traceEnabled
        self.disableFlasherOnBase = disableFlasherOnBase
    }
    
    func resetFrameCounter() { frameCounter = 0 }

    func setDisableFlasherOnBase(_ disabled: Bool) {
        guard disabled != disableFlasherOnBase else { return }
        disableFlasherOnBase = disabled
        os_log("SkylineCoreRenderer: disableFlasherOnBase -> %{public}@", log: log, type: .info, disabled ? "true" : "false")
    }
    
    // Generate sprite instances to draw this frame onto the persistent base texture.
    // Stars and building lights are 1px rects; flasher is a circle.
    func generateSprites() -> [SpriteInstance] {
        if traceEnabled {
            os_log("generating base sprites (no moon) flasherDisabled=%{public}@", log: log, type: .debug, disableFlasherOnBase ? "true" : "false")
        }
        frameCounter &+= 1
        var sprites: [SpriteInstance] = []
        let startCount = sprites.count
        appendStars(into: &sprites)
        let afterStars = sprites.count
        appendBuildingLights(into: &sprites)
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
    
    private func appendStars(into sprites: inout [SpriteInstance]) {
        // Use half-open range to emit exactly skyline.starsPerUpdate items (0 emits none)
        guard skyline.starsPerUpdate > 0 else { return }
        for _ in 0..<skyline.starsPerUpdate {
            let star = skyline.getSingleStar()
            let cx = Float(star.xPos) + 0.5
            let cy = Float(star.yPos) + 0.5
            let half = SIMD2<Float>(repeating: 0.5)
            let color = premulRGBA(r: Float(star.color.red), g: Float(star.color.green), b: Float(star.color.blue), a: 1.0)
            sprites.append(SpriteInstance(centerPx: SIMD2<Float>(cx, cy), halfSizePx: half, colorPremul: color, shape: .rect))
        }
    }
    
    private func appendBuildingLights(into sprites: inout [SpriteInstance]) {
        // Use half-open range to emit exactly skyline.buildingLightsPerUpdate items (0 emits none)
        guard skyline.buildingLightsPerUpdate > 0 else { return }
        for _ in 0..<skyline.buildingLightsPerUpdate {
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
