//
//  SkylineCoreRenderer.swift
//  StarryExcuseForAMacScreensaver
//

import Foundation
import os
import ScreenSaver
import CoreGraphics

class SkylineCoreRenderer {
    let skyline: Skyline
    let log: OSLog
    let starSize = 1
    let traceEnabled: Bool
    
    private var lastMoonRect: CGRect?
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    private var frameCounter: Int = 0
    
    // Brightness factors (from skyline defaults)
    private let brightBrightness: CGFloat
    private let darkBrightness: CGFloat
    
    init(skyline: Skyline, log: OSLog, traceEnabled: Bool) {
        self.skyline = skyline
        self.log = log
        self.traceEnabled = traceEnabled
        self.brightBrightness = CGFloat(skyline.moonBrightBrightness)
        self.darkBrightness = CGFloat(skyline.moonDarkBrightness)
    }
    
    func drawSingleFrame(context: CGContext) {
        if traceEnabled {
            os_log("drawing single frame", log: log, type: .debug)
        }
        frameCounter &+= 1
        drawStars(context: context)
        drawMoon(context: context)
        drawBuildings(context: context)
        drawFlasher(context: context)
    }
    
    func drawStars(context: CGContext) {
        for _ in 0...skyline.starsPerUpdate {
            let star = skyline.getSingleStar()
            drawSinglePoint(point: star, size: starSize, context: context)
        }
    }
    
    func drawBuildings(context: CGContext) {
        for _ in 0...skyline.buildingLightsPerUpdate {
            let light = skyline.getSingleBuildingPoint()
            drawSinglePoint(point: light, size: starSize, context: context)
        }
    }
    
    func drawFlasher(context: CGContext) {
        guard let flasher = skyline.getFlasher() else { return }
        drawSingleCircle(point: flasher, radius: skyline.flasherRadius, context: context)
    }
    
    // MARK: - Moon Rendering (textured, anti-aliased edge, nearest-neighbor internal sampling)
    // Adjusted to REMOVE thin light outline on the dark side by eliminating overlap between
    // bright and dark passes for crescent phases. For crescents we now draw ONLY the bright
    // lens over a previously cleared (black) area. For gibbous phases we draw the bright disc
    // first, then a single dark lens overlay (no dual-edge stacking).
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon(), let texture = moon.textureImage else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(min(max(moon.illuminatedFraction, 0.0), 1.0))
        
        let newThreshold: CGFloat = 0.005
        let fullThreshold: CGFloat = 0.995
        
        // Erase last moon area with a circular clear instead of rectangle to avoid box artifacts
        if let prev = lastMoonRect {
            context.saveGState()
            let clearRect = prev.insetBy(dx: -1, dy: -1)
            context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
            context.addEllipse(in: clearRect)
            context.fillPath()
            context.restoreGState()
        }
        
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .none   // nearest-neighbor for texture itself
        
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        // Simple phases: new or full shortcuts (single pass -> no outlines)
        if f <= newThreshold {
            // New: nothing (optional faint dark moon) - we skip drawing to keep sky clean.
            context.restoreGState(); lastMoonRect = moonRect; return
        } else if f >= fullThreshold {
            drawTexture(context: context, image: texture, in: moonRect, brightness: brightBrightness, clipToCircle: true)
            context.restoreGState(); lastMoonRect = moonRect; return
        }
        
        // Phase geometry
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(0.5, rawEllipseWidth)
        let ellipseRect = CGRect(x: center.x - ellipseWidth/2.0, y: center.y - r, width: ellipseWidth, height: 2*r)
        let lightOnRight = moon.waxing
        
        if debugMoon, frameCounter % debugMoonLogEveryNFrames == 0 {
            os_log("MoonGeom frame=%{public}d f=%.4f waxing=%{public}@ cosθ=%.4f ew=%.3f",
                   log: log, type: .debug,
                   frameCounter, f, lightOnRight ? "true" : "false", cosTheta, ellipseWidth)
        }
        
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        
        let rightSideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
        let leftSideRect  = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
        
        // Lens builder: creates clip region for lens on chosen side (sideRect - ellipse) ∩ circle
        func clipLens(sideRect: CGRect) {
            context.clip(to: sideRect)
            let path = CGMutablePath()
            path.addEllipse(in: ellipseRect)
            path.addRect(moonRect) // large rect for even-odd subtraction
            context.addPath(path)
            context.clip(using: .evenOdd)
        }

        drawTexture(context: context, image: texture, in: moonRect, brightness: brightBrightness, clipToCircle: true)
        context.saveGState()
        context.addEllipse(in: moonRect)
        context.clip()
        if lightOnRight {
            // Dark left lens
            clipLens(sideRect: leftSideRect)
        } else {
            // Dark right lens
            clipLens(sideRect: rightSideRect)
        }
        drawTexture(context: context, image: texture, in: moonRect, brightness: darkBrightness, clipToCircle: false)
        context.restoreGState()

        lastMoonRect = moonRect
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
    
    func convertColor(color: Color) -> CGColor {
        CGColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1.0)
    }
    
    func drawSingleCircle(point: Point, radius: Int = 4, context: CGContext) {
        context.saveGState()
        context.setFillColor(convertColor(color: point.color))
        let rect = CGRect(x: point.xPos - radius, y: point.yPos - radius, width: radius * 2, height: radius * 2)
        context.addEllipse(in: rect)
        context.drawPath(using: .fill)
        context.restoreGState()
    }
    
    func drawSinglePoint(point: Point, size: Int = 10, context: CGContext) {
        context.saveGState()
        context.setFillColor(convertColor(color: point.color))
        context.fill(CGRect(x: point.xPos, y: point.yPos, width: starSize, height: size))
        context.restoreGState()
    }
}
