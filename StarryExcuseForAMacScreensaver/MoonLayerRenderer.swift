import Foundation
import CoreGraphics
import os

// Handles drawing the moon (with optional dark-side radial extension) onto a
// transparent context, independent of the evolving star/building field.
final class MoonLayerRenderer {
    private let skyline: Skyline
    private let log: OSLog
    private let brightBrightness: CGFloat
    private let darkBrightness: CGFloat
    private let showCrescentClipMask: Bool
    // Override for dark-side radial extension (pixels added to radius)
    private let oversizeOverrideEnabled: Bool
    private let oversizeOverrideValue: CGFloat
    
    // internal reuse
    private var frameCounter: Int = 0
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    
    // Dynamic extension (pixels added to dark-side radius) when override disabled.
    // Previously used as a lateral rectangle oversize; now interpreted as
    // an added radial extent beyond the nominal lunar radius ONLY on the
    // dark side, without changing the bright/dark internal terminator.
    private func dynamicDarkSideExtension(forRadius r: CGFloat) -> CGFloat {
        let minRadius: CGFloat = 40.0
        let maxRadius: CGFloat = 150.0
        let minExt: CGFloat = 1.25
        let maxExt: CGFloat = 3.0
        if r <= minRadius { return minExt }
        if r >= maxRadius { return maxExt }
        let t = (r - minRadius) / (maxRadius - minRadius)
        return minExt + t * (maxExt - minExt)
    }
    
    // Allow minimal midline overlap logic retained (not used for new oversize
    // semantics, but still used in crescent clipping to keep slender crescents visible)
    private let centerlineOverlapForDark: CGFloat = 1.0
    
    init(skyline: Skyline,
         log: OSLog,
         brightBrightness: CGFloat,
         darkBrightness: CGFloat,
         showCrescentClipMask: Bool,
         oversizeOverrideEnabled: Bool,
         oversizeOverrideValue: CGFloat) {
        self.skyline = skyline
        self.log = log
        self.brightBrightness = brightBrightness
        self.darkBrightness = darkBrightness
        self.showCrescentClipMask = showCrescentClipMask
        self.oversizeOverrideEnabled = oversizeOverrideEnabled
        self.oversizeOverrideValue = oversizeOverrideValue
    }
    
    @inline(__always)
    private func pixelAlign(_ value: CGFloat) -> CGFloat { round(value) }
    
    func renderMoon(into context: CGContext) {
        frameCounter &+= 1
        guard let moon = skyline.getMoon(),
              let texture = moon.textureImage else { return }
        
        // Center & phase
        let rawCenter = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let center = CGPoint(x: pixelAlign(rawCenter.x), y: pixelAlign(rawCenter.y))
        let fRaw = moon.illuminatedFraction
        let f = CGFloat(min(max(fRaw, 0.0), 1.0))
        let lightOnRight = moon.waxing
        let darkOnRight = !lightOnRight
        
        // Extension (pixels added to radius) for the dark side only
        let darkExtension: CGFloat = oversizeOverrideEnabled
            ? max(0.0, oversizeOverrideValue)
            : dynamicDarkSideExtension(forRadius r)
        
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .none
        
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        let extendedR = r + darkExtension
        let extendedRect = CGRect(x: center.x - extendedR, y: center.y - extendedR, width: 2*extendedR, height: 2*extendedR)
        
        // Near-new / near-full bail-outs where appropriate
        let newThreshold: CGFloat = 0.005
        let fullThreshold: CGFloat = 0.995
        
        // NEW MOON (entirely dark) => whole disk is dark, apply extension
        if f <= newThreshold {
            drawDarkExtendedDisk(context: context,
                                 texture: texture,
                                 extendedRect: extendedRect,
                                 darkOnRight: darkOnRight)
            context.restoreGState()
            return
        }
        
        // FULL MOON (entirely bright) => no dark side to extend
        if f >= fullThreshold {
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: true)
            context.restoreGState()
            return
        }
        
        // Phase split: f <= 0.5 -> bright minority (crescent); f > 0.5 -> dark minority (gibbous)
        if f <= 0.5 {
            // BRIGHT MINORITY (crescent). Majority (dark) should extend outwards on dark side.
            // 1. Draw extended dark base (covers dark side outside original radius + dark interior)
            drawDarkExtendedDisk(context: context,
                                 texture: texture,
                                 extendedRect: extendedRect,
                                 darkOnRight: darkOnRight)
            // 2. Overlay bright crescent inside original circle (terminator unchanged)
            drawBrightCrescentOverDarkMajority(context: context,
                                               texture: texture,
                                               moonRect: moonRect,
                                               radius: r,
                                               fraction: f,
                                               lightOnRight: lightOnRight)
        } else {
            // BRIGHT MAJORITY (gibbous). Bright stays confined to original radius. Dark minority extends outward.
            // 1. Draw bright majority (original circle)
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: true)
            // 2. Draw dark minority crescent (inside original radius) + outward extension ring
            drawDarkMinorityWithExtension(context: context,
                                          texture: texture,
                                          moonRect: moonRect,
                                          extendedRect: extendedRect,
                                          radius: r,
                                          fraction: f,
                                          lightOnRight: lightOnRight,
                                          darkOnRight: darkOnRight)
        }
        
        context.restoreGState()
    }
    
    // MARK: - Drawing Helpers
    
    // Draw extended dark disk (only the dark-side half is extended beyond original radius).
    private func drawDarkExtendedDisk(context: CGContext,
                                      texture: CGImage,
                                      extendedRect: CGRect,
                                      darkOnRight: Bool) {
        context.saveGState()
        // Clip to extended circle
        context.addEllipse(in: extendedRect)
        context.clip()
        // Clip to dark side half-plane
        let halfRect: CGRect
        if darkOnRight {
            halfRect = CGRect(x: extendedRect.midX,
                              y: extendedRect.minY,
                              width: extendedRect.width / 2,
                              height: extendedRect.height)
        } else {
            halfRect = CGRect(x: extendedRect.minX,
                              y: extendedRect.minY,
                              width: extendedRect.width / 2,
                              height: extendedRect.height)
        }
        context.clip(to: halfRect)
        // Draw scaled texture (so features extend, Option A)
        drawTexture(context: context,
                    image: texture,
                    in: extendedRect,
                    brightness: darkBrightness,
                    clipToCircle: false) // already clipped
        if showCrescentClipMask {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
            context.fill(extendedRect)
        }
        context.restoreGState()
    }
    
    // Draw the bright crescent (minority) onto an already-drawn dark majority+extension.
    private func drawBrightCrescentOverDarkMajority(context: CGContext,
                                                    texture: CGImage,
                                                    moonRect: CGRect,
                                                    radius r: CGFloat,
                                                    fraction f: CGFloat,
                                                    lightOnRight: Bool) {
        // Geometry for bright minority uses fraction f
        let (ellipseRect, rightSideRect, leftSideRect, _, _) =
            phaseGeometry(radius: r, center: CGPoint(x: moonRect.midX, y: moonRect.midY), fraction: f)
        
        context.saveGState()
        // Restrict to original circle (bright shouldn't escape original limb)
        context.addEllipse(in: moonRect)
        context.clip()
        context.saveGState()
        // Clip to bright crescent (reuse existing crescent logic with oversize=0)
        if lightOnRight {
            clipCrescent(context: context,
                         moonRect: moonRect,
                         ellipseRect: ellipseRect,
                         sideRect: rightSideRect,
                         preventCrossingCenterline: false,
                         darkFraction: nil,
                         darkOnRightSide: nil)
        } else {
            clipCrescent(context: context,
                         moonRect: moonRect,
                         ellipseRect: ellipseRect,
                         sideRect: leftSideRect,
                         preventCrossingCenterline: false,
                         darkFraction: nil,
                         darkOnRightSide: nil)
        }
        if showCrescentClipMask {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
            context.fill(moonRect)
        } else {
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: brightBrightness,
                        clipToCircle: false)
        }
        context.restoreGState()
        context.restoreGState()
    }
    
    // Draw dark minority inside original circle + its outward extension ring beyond original radius.
    private func drawDarkMinorityWithExtension(context: CGContext,
                                               texture: CGImage,
                                               moonRect: CGRect,
                                               extendedRect: CGRect,
                                               radius r: CGFloat,
                                               fraction f: CGFloat,
                                               lightOnRight: Bool,
                                               darkOnRight: Bool) {
        let darkFraction = CGFloat(1.0 - f) // minority
        if darkFraction <= 0 { return }
        let (ellipseRect, rightSideRect, leftSideRect, _, _) =
            phaseGeometry(radius: r, center: CGPoint(x: moonRect.midX, y: moonRect.midY), fraction: darkFraction)
        
        // 1. Dark crescent INSIDE original circle (terminator boundary)
        context.saveGState()
        context.addEllipse(in: moonRect)
        context.clip()
        context.saveGState()
        if darkOnRight {
            // Dark crescent on right
            clipCrescent(context: context,
                         moonRect: moonRect,
                         ellipseRect: ellipseRect,
                         sideRect: rightSideRect,
                         preventCrossingCenterline: true,
                         darkFraction: darkFraction,
                         darkOnRightSide: true)
        } else {
            // Dark crescent on left
            clipCrescent(context: context,
                         moonRect: moonRect,
                         ellipseRect: ellipseRect,
                         sideRect: leftSideRect,
                         preventCrossingCenterline: true,
                         darkFraction: darkFraction,
                         darkOnRightSide: false)
        }
        if showCrescentClipMask {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
            context.fill(moonRect)
        } else {
            drawTexture(context: context,
                        image: texture,
                        in: moonRect,
                        brightness: darkBrightness,
                        clipToCircle: false)
        }
        context.restoreGState()
        context.restoreGState()
        
        // 2. Extension ring: (extended circle - original circle) ∩ dark half-plane
        context.saveGState()
        // Clip to extension ring
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: extendedRect)
        ringPath.addEllipse(in: moonRect)
        context.addPath(ringPath)
        context.clip(using: .evenOdd)
        // Clip to dark half-plane
        let halfRect: CGRect
        if darkOnRight {
            halfRect = CGRect(x: extendedRect.midX,
                              y: extendedRect.minY,
                              width: extendedRect.width / 2,
                              height: extendedRect.height)
        } else {
            halfRect = CGRect(x: extendedRect.minX,
                              y: extendedRect.minY,
                              width: extendedRect.width / 2,
                              height: extendedRect.height)
        }
        context.clip(to: halfRect)
        // Draw dark texture scaled to extended radius
        drawTexture(context: context,
                    image: texture,
                    in: extendedRect,
                    brightness: darkBrightness,
                    clipToCircle: false) // already clipped
        if showCrescentClipMask {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
            context.fill(extendedRect)
        }
        context.restoreGState()
    }
    
    // MARK: - Phase Geometry & Clipping (unchanged core logic)
    
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
    
    // Clip path to a crescent (bright or dark) inside the original circle.
    // NOTE: oversize adjustments were removed per new semantics (extension now radial).
    private func clipCrescent(context: CGContext,
                              moonRect: CGRect,
                              ellipseRect: CGRect,
                              sideRect: CGRect,
                              preventCrossingCenterline: Bool,
                              darkFraction: CGFloat?,
                              darkOnRightSide: Bool?) {
        var sr = sideRect
        let moonCenterX = moonRect.midX
        
        if preventCrossingCenterline,
           let df = darkFraction,
           let rightSide = darkOnRightSide {
            let scaledOverlap = max(0.5, centerlineOverlapForDark * max(0.35, Double(df)))
            if rightSide {
                let desiredMin = moonCenterX - CGFloat(scaledOverlap)
                if sr.minX < desiredMin {
                    let delta = desiredMin - sr.minX
                    sr.origin.x += delta
                    sr.size.width -= delta
                }
            } else {
                let desiredMax = moonCenterX + CGFloat(scaledOverlap)
                if sr.maxX > desiredMax {
                    sr.size.width = max(0, desiredMax - sr.minX)
                }
            }
            if rightSide {
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
        
        if sr.width <= 0 { return }
        
        context.clip(to: sr)
        let path = CGMutablePath()
        path.addEllipse(in: ellipseRect)
        path.addRect(moonRect)
        context.addPath(path)
        context.clip(using: .evenOdd)
    }
    
    // MARK: - Texture Drawing
    
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
