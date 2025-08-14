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
    private let showCrescentClipMask: Bool
    private let oversizeOverrideEnabled: Bool
    private let oversizeOverrideValue: CGFloat
    
    // internal reuse
    private var frameCounter: Int = 0
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    
    // Dynamic oversizing scaling with radius (only used when override disabled)
    private func scaledDarkMinorityOversize(forRadius r: CGFloat) -> CGFloat {
        let minRadius: CGFloat = 40.0
        let maxRadius: CGFloat = 150.0
        let minOversize: CGFloat = 1.25
        let maxOversize: CGFloat = 3.0
        if r <= minRadius { return minOversize }
        if r >= maxRadius { return maxOversize }
        let t = (r - minRadius) / (maxRadius - minRadius)
        return minOversize + t * (maxOversize - minOversize)
    }
    
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
    private func pixelAlign(_ value: CGFloat) -> CGFloat {
        return round(value)
    }
    
    func renderMoon(into context: CGContext) {
        frameCounter &+= 1
        guard let moon = skyline.getMoon(),
              let texture = moon.textureImage else { return }
        
        let rawCenter = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let fRaw = moon.illuminatedFraction
        let f = CGFloat(min(max(fRaw, 0.0), 1.0))
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
        
        let lightOnRight = moon.waxing
        
        if f <= 0.5 {
            // Bright minority phase (crescent)
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
            
        } else {
            // Bright majority phase (gibbous)
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
                
                let dynamicOversize = oversizeOverrideEnabled ?
                    oversizeOverrideValue :
                    scaledDarkMinorityOversize(forRadius: r)
                
                context.saveGState()
                context.addEllipse(in: moonRect)
                context.clip()
                
                context.saveGState()
                if lightOnRight {
                    // Dark crescent on left
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: leftSideRect,
                                 oversize: dynamicOversize,
                                 preventCrossingCenterline: true,
                                 darkFraction: darkFraction,
                                 darkOnRightSide: false)
                } else {
                    // Dark crescent on right
                    clipCrescent(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 sideRect: rightSideRect,
                                 oversize: dynamicOversize,
                                 preventCrossingCenterline: true,
                                 darkFraction: darkFraction,
                                 darkOnRightSide: true)
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
            }
        }
        
        context.restoreGState()
    }
    
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
        
        if oversize > 0 {
            if sr.minX < moonCenterX {
                sr.origin.x -= oversize
                sr.size.width += oversize
            } else {
                sr.size.width += oversize
            }
        }
        
        if preventCrossingCenterline, let df = darkFraction, let rightSide = darkOnRightSide {
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
