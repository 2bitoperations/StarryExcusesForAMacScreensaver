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
    // outward (toward the limb) and NEVER allowed to erase the narrow dark sliver.
    // Tune if needed (0.5 .. 2.0 typical).
    private let darkMinorityOversize: CGFloat = 1.25
    
    // When clamping the dark minority crescent we previously snapped the side
    // rectangle exactly to the moon centerline. For early waning / waxing gibbous
    // phases (fraction just below 1.0, i.e. slider in ~0.5 .. 0.75 or ~0.25 .. 0.5
    // depending on direction) this eliminated the narrow dark sliver completely,
    // making the moon appear full. We now allow a thin overlap past the centerline
    // so the even‑odd (circle XOR ellipse) operation still yields a crescent.
    // This is a minimal pixel width (in logical points) retained across midline.
    private let centerlineOverlapForDark: CGFloat = 1.0
    
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
        // For the gibbous branch we guarantee the "dark minority crescent"
        // does not extend far across the centerline while still keeping a
        // minimal overlap so the XOR mask produces a visible sliver.
        
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
                             preventCrossingCenterline: false,
                             darkFraction: nil,
                             darkOnRightSide: nil)
            } else {
                clipCrescent(context: context,
                             moonRect: moonRect,
                             ellipseRect: ellipseRect,
                             sideRect: leftSideRect,
                             oversize: 0.0,
                             preventCrossingCenterline: false,
                             darkFraction: nil,
                             darkOnRightSide: nil)
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
                    // Light on right => dark crescent on LEFT
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: leftSideRect,
                                 oversize: darkMinorityOversize,
                                 preventCrossingCenterline: true,
                                 darkFraction: darkFraction,
                                 darkOnRightSide: false)
                } else {
                    // Light on left => dark crescent on RIGHT
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: rightSideRect,
                                 oversize: darkMinorityOversize,
                                 preventCrossingCenterline: true,
                                 darkFraction: darkFraction,
                                 darkOnRightSide: true)
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
    // preventCrossingCenterline: when true, clamps side rect so dark overlay doesn't
    //                             swallow the bright hemisphere. We now retain a
    //                             minimal centerline overlap so the XOR result does
    //                             not vanish (which previously caused a "full" moon
    //                             appearance for early gibbous).
    // darkFraction / darkOnRightSide: used to tailor clamping based on which side
    //                                 the dark region is on and how large it is.
    private func clipCrescent(context: CGContext,
                              moonRect: CGRect,
                              ellipseRect: CGRect,
                              sideRect: CGRect,
                              oversize: CGFloat,
                              preventCrossingCenterline: Bool,
                              darkFraction: CGFloat?,
                              darkOnRightSide: Bool?) {
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
        
        if preventCrossingCenterline, let df = darkFraction, let rightSide = darkOnRightSide {
            // Allow a narrow overlap across the centerline; use centerlineOverlapForDark,
            // but scale it slightly with darkFraction so very small dark slivers
            // still survive the XOR mask.
            let scaledOverlap = max(0.5, centerlineOverlapForDark * max(0.35, Double(df)))
            
            if rightSide {
                // Dark crescent on RIGHT
                // Previously: newMinX = center -> lost sliver. Now allow small overlap into left.
                let desiredMin = moonCenterX - CGFloat(scaledOverlap)
                if sr.minX < desiredMin {
                    let delta = desiredMin - sr.minX
                    sr.origin.x += delta
                    sr.size.width -= delta
                }
            } else {
                // Dark crescent on LEFT
                // Keep maxX a little past center to preserve XOR area.
                let desiredMax = moonCenterX + CGFloat(scaledOverlap)
                if sr.maxX > desiredMax {
                    sr.size.width = max(0, desiredMax - sr.minX)
                }
            }
            // Also enforce that we don't extend far into the bright hemisphere:
            if rightSide {
                // Prevent right dark rect from starting too far left ( > half + overlap limit)
                let absoluteMin = moonCenterX - 2.0 * CGFloat(scaledOverlap)
                if sr.minX < absoluteMin {
                    let delta = absoluteMin - sr.minX
                    sr.origin.x += delta
                    sr.size.width -= delta
                }
            } else {
                let absoluteMax = moonCenterX + 2.0 * CGFloat(scaledOverlap)
                if sr.maxX > absoluteMax {
                    sr.size.width = max(0, absoluteMax - sr.minX)
                }
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
