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
    
    // Oversizing used ONLY to ensure the dark minority crescent fully covers any
    // bright fringe along the OUTER limb (sky boundary). This expansion is applied
    // outward (toward the limb) and NEVER allowed to cross the moon centerline.
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
        
        // Align center so bitmap + clip are stable relative to pixel grid.
        let center = CGPoint(x: pixelAlign(rawCenter.x),
                             y: pixelAlign(rawCenter.y))
        
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .none
        
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        // Thresholds for near-new / near-full.
        let newThreshold: CGFloat = 0.005
        let fullThreshold: CGFloat = 0.995
        
        if f <= newThreshold {
            context.restoreGState()
            return
        } else if f >= fullThreshold {
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: true)
            context.restoreGState()
            return
        }
        
        // Determine illuminated side (Northern Hemisphere convention).
        let lightOnRight = moon.waxing
        
        // Branches:
        // (1) Crescent  (f <= 0.5): dark full disc base, then bright minority crescent.
        // (2) Gibbous   (f > 0.5):  bright full disc base, then dark minority crescent.
        //
        // NEW CHANGE: For the gibbous branch we guarantee the "dark minority crescent"
        // NEVER extends past the moon's centerline (mid-X). We still allow a small
        // outward oversize toward the limb to avoid a residual bright rim, but we
        // clamp the clipping rectangle so it cannot intrude into the bright majority.
        
        if f <= 0.5 {
            // ---------------------------
            // CRESCENT PHASE (bright minority)
            // ---------------------------
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: darkBrightness,
                        clipToCircle: true)
            
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
            
            context.saveGState()
            // Bright crescent (minority) – no oversize & no centerline clamp needed
            if lightOnRight {
                clipCrescent(context: context,
                             moonRect: moonRect,
                             ellipseRect: ellipseRect,
                             sideRect: rightSideRect,
                             oversize: 0.0,
                             preventCrossingCenterline: false)
            } else {
                clipCrescent(context: context,
                             moonRect: moonRect,
                             ellipseRect: ellipseRect,
                             sideRect: leftSideRect,
                             oversize: 0.0,
                             preventCrossingCenterline: false)
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
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: true)
            
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
                context.addEllipse(in: moonRect)
                context.clip()
                
                context.saveGState()
                if lightOnRight {
                    // Light on right => dark crescent on left (outward oversize but clamp to center)
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: leftSideRect,
                                 oversize: darkMinorityOversize,
                                 preventCrossingCenterline: true)
                } else {
                    // Light on left => dark crescent on right
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: rightSideRect,
                                 oversize: darkMinorityOversize,
                                 preventCrossingCenterline: true)
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
    
    private func phaseGeometry(radius r: CGFloat,
                               center: CGPoint,
                               fraction f: CGFloat) -> (CGRect, CGRect, CGRect, CGFloat, CGFloat) {
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
    
    // Applies clipping to isolate a crescent (bright or dark) by performing a
    // symmetric difference (moonRect XOR ellipse) restricted to a (possibly
    // oversized) side rectangle.
    //
    // oversize: outward expansion toward the limb ONLY (never into the bright majority).
    // preventCrossingCenterline: when true, clamps the side rectangle so the dark
    //                             overlay cannot cross the moon's vertical midline.
    private func clipCrescent(context: CGContext,
                              moonRect: CGRect,
                              ellipseRect: CGRect,
                              sideRect: CGRect,
                              oversize: CGFloat,
                              preventCrossingCenterline: Bool) {
        var sr = sideRect
        let moonCenterX = moonRect.midX
        
        // Determine side & apply outward oversize
        if oversize > 0 {
            if sr.minX < moonCenterX {
                // LEFT side: expand toward limb (further left)
                sr.origin.x -= oversize
                sr.size.width += oversize
            } else {
                // RIGHT side: expand toward limb (further right)
                sr.size.width += oversize
            }
        }
        
        // Clamp so dark region never crosses centerline if requested
        if preventCrossingCenterline {
            if sr.minX < moonCenterX {
                // Left dark crescent: restrict to left half
                let maxX = min(sr.maxX, moonCenterX)
                sr.size.width = max(0, maxX - sr.minX)
            } else {
                // Right dark crescent: restrict to right half
                let newMinX = max(sr.minX, moonCenterX)
                let oldMaxX = sr.maxX
                sr.origin.x = newMinX
                sr.size.width = max(0, oldMaxX - newMinX)
            }
        }
        
        // If clipping collapsed (edge case), nothing to render
        if sr.width <= 0 {
            return
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

private extension CGRect {
    var maxX: CGFloat { origin.x + size.width }
}
