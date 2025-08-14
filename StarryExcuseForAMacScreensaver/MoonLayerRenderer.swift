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
    
    func renderMoon(into context: CGContext) {
        frameCounter &+= 1
        guard let moon = skyline.getMoon(),
              let texture = moon.textureImage else { return }
        
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(min(max(moon.illuminatedFraction, 0.0), 1.0))
        
        // Transparent background assumed. We only draw the moon shape so that
        // uncovering regions shows whatever has accumulated beneath.
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
            drawTexture(context: context, image: texture, in: moonRect, brightness: brightBrightness, clipToCircle: true)
            context.restoreGState()
            return
        }
        
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(0.5, rawEllipseWidth)
        let ellipseRect = CGRect(x: center.x - ellipseWidth/2.0, y: center.y - r, width: ellipseWidth, height: 2*r)
        let lightOnRight = moon.waxing
        
        if debugMoon, frameCounter % debugMoonLogEveryNFrames == 0 {
            os_log("MoonLayer frame=%{public}d f=%.4f waxing=%{public}@ cosθ=%.4f ew=%.3f",
                   log: log, type: .debug,
                   frameCounter, f, lightOnRight ? "true" : "false", cosTheta, ellipseWidth)
        }
        
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        
        let rightSideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
        let leftSideRect  = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
        
        func clipLens(sideRect: CGRect) {
            context.clip(to: sideRect)
            let path = CGMutablePath()
            path.addEllipse(in: ellipseRect)
            path.addRect(moonRect)
            context.addPath(path)
            context.clip(using: .evenOdd)
        }
        
        // Bright disc first
        drawTexture(context: context, image: texture, in: moonRect, brightness: brightBrightness, clipToCircle: true)
        
        // Dark lens overlay
        context.saveGState()
        context.addEllipse(in: moonRect)
        context.clip()
        if lightOnRight {
            clipLens(sideRect: leftSideRect)
        } else {
            clipLens(sideRect: rightSideRect)
        }
        drawTexture(context: context, image: texture, in: moonRect, brightness: darkBrightness, clipToCircle: false)
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
