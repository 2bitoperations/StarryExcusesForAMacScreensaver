import Foundation
import CoreGraphics
import os

// Handles drawing the moon onto a transparent context, independent of the
// evolving star/building field. Supports being called infrequently (e.g. once
// per second) while the base field continues to accumulate.
final class MoonLayerRenderer {
    private let skyline: Skyline
    private let log: OSLog
    private let brightBrightness: CGFloat
    private let darkBrightness: CGFloat
    
    // internal reuse
    private var frameCounter: Int = 0
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    
    init(skyline: Skyline,
         log: OSLog,
         brightBrightness: CGFloat,
         darkBrightness: CGFloat) {
        self.skyline = skyline
        self.log = log
        self.brightBrightness = brightBrightness
        self.darkBrightness = darkBrightness
    }
    
    // Pixel alignment helper: snaps a CGFloat to the nearest device pixel.
    // (Currently assumes backing scale == 1 for the offscreen context dimensions.
    // If a backing scale factor is introduced later, multiply, round, divide.)
    @inline(__always)
    private func pixelAlign(_ value: CGFloat) -> CGFloat {
        return round(value)
    }
    
    func renderMoon(into context: CGContext) {
        frameCounter &+= 1
        guard let moon = skyline.getMoon(),
              let texture = moon.textureImage else { return }
        
        // Original (potentially fractional) center.
        let rawCenter = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(min(max(moon.illuminatedFraction, 0.0), 1.0))
        
        // Align center so bitmap + clip are stable relative to pixel grid, preventing jitter.
        let center = CGPoint(x: pixelAlign(rawCenter.x),
                             y: pixelAlign(rawCenter.y))
        
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .none
        
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        let newThreshold: CGFloat = 0.005
        let fullThreshold: CGFloat = 0.995
        
        if f <= newThreshold {
            // New moon -> nothing drawn
            context.restoreGState()
            return
        } else if f >= fullThreshold {
            // Full moon -> draw bright disc once
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: true)
            context.restoreGState()
            return
        }
        
        // Partial phase:
        // Draw strategy (fixes bright halo on dark limb):
        // 1. Draw entire disc at darkBrightness (base).
        // 2. Overlay ONLY the illuminated portion at brightBrightness.
        // This avoids relying on perfectly covering the bright disc with a dark overlay,
        // eliminating the thin bright rim artifact.
        
        // Step 1: dark base disc
        drawTexture(context: context,
                    image: texture,
                    in: moonRect,
                    brightness: darkBrightness,
                    clipToCircle: true)
        
        // Step 2: illuminated segment overlay
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(0.5, rawEllipseWidth)
        let ellipseRect = CGRect(x: center.x - ellipseWidth/2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: 2*r)
        let lightOnRight = moon.waxing
        
        if debugMoon, frameCounter % debugMoonLogEveryNFrames == 0 {
            os_log("MoonLayer frame=%{public}d f=%.4f waxing=%{public}@ cosθ=%.4f ew=%.3f",
                   log: log, type: .debug,
                   frameCounter, f, lightOnRight ? "true" : "false", cosTheta, ellipseWidth)
        }
        
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        let rightSideRect = CGRect(x: centerX - overlap,
                                   y: moonRect.minY,
                                   width: r + overlap,
                                   height: moonRect.height)
        let leftSideRect  = CGRect(x: centerX - r,
                                   y: moonRect.minY,
                                   width: r + overlap,
                                   height: moonRect.height)
        
        // clipLens isolates a crescent/gibbous region based on the sideRect provided.
        // After we changed layering (dark base first) the semantic of which sideRect
        // yields the LIT portion inverted relative to the previous code. Therefore
        // we intentionally feed the *opposite* sideRect of the visual lit side.
        func clipLens(sideRect: CGRect) {
            context.clip(to: sideRect)
            let path = CGMutablePath()
            path.addEllipse(in: ellipseRect)
            path.addRect(moonRect)
            context.addPath(path)
            context.clip(using: .evenOdd)
        }
        
        context.saveGState()
        // Restrict to moon circle first (for antialiased rim coherence)
        context.addEllipse(in: moonRect)
        context.clip()
        // Choose sideRect to produce illuminated region:
        // If light should appear on the RIGHT, we must pass leftSideRect (and vice versa)
        // due to even-odd + sideRect intersection producing the complement after layering change.
        if lightOnRight {
            clipLens(sideRect: leftSideRect)
        } else {
            clipLens(sideRect: rightSideRect)
        }
        drawTexture(context: context,
                    image: texture,
                    in: moonRect,
                    brightness: brightBrightness,
                    clipToCircle: false)
        context.restoreGState()
        
        context.restoreGState()
    }
    
    private func drawTexture(context: CGContext,
                             image: CGImage,
                             in rect: CGRect,
                             brightness: CGFloat,
                             clipToCircle: Bool) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        if clipToCircle {
            context.addEllipse(in: rect)
            context.clip()
        }
        context.draw(image, in: rect)
        if brightness < 0.999 {
            let alpha = min(1.0, max(0.0, 1.0 - brightness))
            if alpha > 0 {
                context.setFillColor(CGColor(gray: 0.0, alpha: alpha))
                context.fill(rect)
            }
        }
        context.restoreGState()
    }
}
