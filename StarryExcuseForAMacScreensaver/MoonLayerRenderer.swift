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
    
    // Oversizing (in logical pixels) applied to the dark minority overlay during
    // gibbous phases to ensure no bright fringe remains along the dark limb after
    // antialiasing / interpolation. This slightly expands the clipping side rect
    // further into the bright region before the even-odd crescent mask is applied.
    // Tune if needed (0.5 .. 2.0 typical).
    private let darkMinorityOversize: CGFloat = 1.25
    
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
        let fRaw = moon.illuminatedFraction
        let f = CGFloat(min(max(fRaw, 0.0), 1.0))
        
        // Align center so bitmap + clip are stable relative to pixel grid, preventing jitter.
        let center = CGPoint(x: pixelAlign(rawCenter.x),
                             y: pixelAlign(rawCenter.y))
        
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .none
        
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        // Thresholds for near-new / near-full (avoid pathological geometry).
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
        
        // Determine which side is illuminated (Northern Hemisphere convention).
        // waxing  : illuminated portion on RIGHT
        // waning  : illuminated portion on LEFT
        let lightOnRight = moon.waxing
        
        // Two rendering branches:
        //  (1) Crescent (f <= 0.5): draw dark full disc, then overlay bright CRESCENT.
        //  (2) Gibbous  (f > 0.5): draw BRIGHT full disc, then overlay dark MINORITY
        //      crescent using fraction (1 - f). To eliminate residual bright rim
        //      artifacts along the dark limb (caused by anti-aliased circle edge
        //      not fully covered by the dark overlay mask), we oversize the side
        //      clipping rect slightly before applying the crescent mask.
        
        if f <= 0.5 {
            // ---------------------------
            // CRESCENT PHASE (bright minority)
            // ---------------------------
            
            // Step 1: dark base disc
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: darkBrightness,
                        clipToCircle: true)
            
            // Geometry for bright crescent based on illuminated fraction f
            let (ellipseRect, rightSideRect, leftSideRect, cosTheta, ellipseWidth) =
                phaseGeometry(radius: r, center: center, fraction: f)
            
            if debugMoon, frameCounter % debugMoonLogEveryNFrames == 0 {
                os_log("MoonLayer crescent frame=%{public}d f=%.4f waxing=%{public}@ cosθ=%.4f ew=%.3f",
                       log: log, type: .debug,
                       frameCounter, f, lightOnRight ? "true" : "false", cosTheta, ellipseWidth)
            }
            
            context.saveGState()
            context.addEllipse(in: moonRect)
            context.clip()
            
            // For bright crescent we clip to the illuminated side directly (no oversize needed).
            context.saveGState()
            if lightOnRight {
                clipCrescent(context: context,
                             moonRect: moonRect,
                             ellipseRect: ellipseRect,
                             sideRect: rightSideRect,
                             oversize: 0.0)
            } else {
                clipCrescent(context: context,
                             moonRect: moonRect,
                             ellipseRect: ellipseRect,
                             sideRect: leftSideRect,
                             oversize: 0.0)
            }
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: false)
            context.restoreGState()
            
            context.restoreGState()
            
        } else {
            // ---------------------------
            // GIBBOUS PHASE (bright majority)
            // ---------------------------
            // Step 1: bright base disc (majority)
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: true)
            
            // Step 2: overlay dark minority crescent, with oversize to suppress bright limb fringe
            let darkFraction = CGFloat(1.0 - f)
            if darkFraction > 0.0 {
                let (ellipseRect, rightSideRect, leftSideRect, cosTheta, ellipseWidth) =
                    phaseGeometry(radius: r, center: center, fraction: darkFraction)
                
                if debugMoon, frameCounter % debugMoonLogEveryNFrames == 0 {
                    os_log("MoonLayer gibbous frame=%{public}d f=%.4f darkFrac=%.4f waxing=%{public}@ cosθ=%.4f ew=%.3f",
                           log: log, type: .debug,
                           frameCounter, f, darkFraction, lightOnRight ? "true" : "false", cosTheta, ellipseWidth)
                }
                
                context.saveGState()
                context.addEllipse(in: moonRect) // ensure we never draw outside the limb
                context.clip()
                
                context.saveGState()
                if lightOnRight {
                    // Light on right => dark crescent on left (oversized for rim coverage)
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: leftSideRect,
                                 oversize: darkMinorityOversize)
                } else {
                    // Light on left => dark crescent on right
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: rightSideRect,
                                 oversize: darkMinorityOversize)
                }
                drawTexture(context: context,
                            image: texture,
                            in: moonRect,
                            brightness: darkBrightness,
                            clipToCircle: false)
                context.restoreGState()
                
                context.restoreGState()
            }
        }
        
        context.restoreGState()
    }
    
    // MARK: - Phase Geometry Helper
    
    // Returns geometry needed to build crescent/gibbous clipping:
    // ellipseRect: the "lens" ellipse
    // rightSideRect / leftSideRect: side rectangles used to isolate one side of XOR
    // cosTheta, ellipseWidth: debug values
    private func phaseGeometry(radius r: CGFloat,
                               center: CGPoint,
                               fraction f: CGFloat) -> (CGRect, CGRect, CGRect, CGFloat, CGFloat) {
        // Using same parameterization: cosTheta = 1 - 2f
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(0.5, rawEllipseWidth)
        let ellipseRect = CGRect(x: center.x - ellipseWidth / 2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: 2 * r)
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        let rightSideRect = CGRect(x: centerX - overlap,
                                   y: moonRect.minY,
                                   width: r + overlap,
                                   height: moonRect.height)
        let leftSideRect = CGRect(x: centerX - r,
                                  y: moonRect.minY,
                                  width: r + overlap,
                                  height: moonRect.height)
        return (ellipseRect, rightSideRect, leftSideRect, cosTheta, ellipseWidth)
    }
    
    // Applies clipping to isolate the crescent (bright or dark depending on layering)
    // by performing a symmetric difference (XOR) between the ellipse "lens" and the
    // full moon disc, restricted to a (possibly oversized) side rectangle.
    //
    // oversize > 0 expands the side rect further across the moon's interior to ensure
    // coverage passes slightly beyond the theoretical terminator limb, reducing halos.
    private func clipCrescent(context: CGContext,
                              moonRect: CGRect,
                              ellipseRect: CGRect,
                              sideRect: CGRect,
                              oversize: CGFloat) {
        var sr = sideRect
        if oversize > 0 {
            // Determine side: if sr.minX < moon center, it's the left; else right.
            let moonCenterX = moonRect.midX
            if sr.minX < moonCenterX {
                // Left side: extend further right (into illuminated area) to ensure full cover.
                sr.size.width += oversize
            } else {
                // Right side: extend leftwards.
                sr.origin.x -= oversize
                sr.size.width += oversize
            }
        }
        context.clip(to: sr)
        let path = CGMutablePath()
        path.addEllipse(in: ellipseRect)
        path.addRect(moonRect)
        context.addPath(path)
        context.clip(using: .evenOdd)
    }
    
    // MARK: - Texture Draw Helper
    
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
