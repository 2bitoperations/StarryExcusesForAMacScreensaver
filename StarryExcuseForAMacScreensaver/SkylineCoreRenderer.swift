//
//
//  SkylineCoreRenderer.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 2019-04-29
//  forked from Marcus Kida's work https://github.com/kimar/DeveloperExcuses
//  port of Evan Green's implementation for Windows https://github.com/evangreen/starryn
//  released under the MIT license
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
    
    // Track previous moon bounds so we can erase it and avoid a trail.
    private var lastMoonRect: CGRect?
    
    // MARK: - Moon Debug / Instrumentation Flags
    
    // Toggle master moon debug instrumentation.
    // Set to false to disable all added logging / overlays.
    private let debugMoon = true
    
    // Log geometry every N frames (set to 1 to log every frame).
    private let debugMoonLogEveryNFrames = 30
    
    // Draw diagnostic overlays (ellipse outline, half-plane boundary, center line).
    private let debugMoonDrawOverlays = true
    
    // Disable antialiasing during crescent/gibbous overlay construction (helps isolate seam issues).
    private let debugDisableAAOverlayPhase = false
    
    // Draw an outline for the carved (terminator) ellipse AFTER operations to see final shape.
    private let debugDrawFinalEllipseOutline = true
    
    // Keep a frame counter to coordinate periodic logging.
    private var frameCounter: Int = 0
    
    init(skyline: Skyline, log: OSLog, traceEnabled: Bool) {
        self.skyline = skyline
        self.log = log
        self.traceEnabled = traceEnabled
    }
    
    func drawSingleFrame(context: CGContext) {
        if (traceEnabled) {
            os_log("drawing single frame", log: self.log, type: .debug)
        }
        frameCounter &+= 1 // wraps on overflow
        // Stars first so the moon & buildings overwrite them (no star over the moon).
        drawStars(context: context)
        drawMoon(context: context)
        drawBuildings(context: context)
        drawFlasher(context: context)
    }
    
    func drawTestLine(context: CGContext) {
        for xIndex in 0...skyline.width {
            let point = Point(xPos: xIndex, yPos: 10 + xIndex, color: Color(red: 0.0, green: 0.0, blue: 1.0))
            drawSinglePoint(point: point, context: context)
        }
    }
    
    func drawStars(context: CGContext) {
        for _ in 0...skyline.starsPerUpdate {
            let star = skyline.getSingleStar()
            self.drawSinglePoint(point: star, size: starSize, context: context)
        }
    }
    
    func drawBuildings(context: CGContext) {
        for _ in 0...skyline.buildingLightsPerUpdate {
            let light = skyline.getSingleBuildingPoint()
            self.drawSinglePoint(point: light, size: starSize, context: context)
        }
    }
    
    func drawFlasher(context: CGContext) {
        guard let flasher = skyline.getFlasher() else {
            return
        }
        self.drawSingleCircle(point: flasher, radius: skyline.flasherRadius, context: context)
    }
    
    // MARK: - Moon Rendering (orthographic-inspired terminator)
    //
    // Debug instrumentation added to investigate vertical seam (dark center line):
    //  - Periodic logging of geometric parameters.
    //  - Optional removal of antialiasing during overlay phase.
    //  - Diagnostic overlays: ellipse outline, half-plane rectangle boundary, center line.
    //
    // Improvement already present:
    //  - Minimum ellipse width clamp (>= 2 px) to reduce sub-pixel flicker.
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon() else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(max(0.0, min(1.0, moon.illuminatedFraction)))
        
        let lightGray = CGColor(gray: 0.85, alpha: 1.0)
        let darkGray  = CGColor(gray: 0.08, alpha: 1.0)
        let outlineGray = CGColor(gray: 0.6, alpha: 1.0)
        
        // Tolerances for pure new/full handling
        let newThreshold: CGFloat = 0.005
        let fullThreshold: CGFloat = 0.995
        
        // Erase previous moon (if any) to prevent trail.
        if let prev = lastMoonRect {
            context.saveGState()
            context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
            // Slight inflate for antialiased edges.
            context.fill(prev.insetBy(dx: -1, dy: -1))
            context.restoreGState()
        }
        
        context.saveGState()
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        if f <= newThreshold {
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            strokeLimb(context: context, rect: moonRect, outline: outlineGray)
            context.restoreGState()
            lastMoonRect = moonRect
            return
        } else if f >= fullThreshold {
            context.setFillColor(lightGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            strokeLimb(context: context, rect: moonRect, outline: outlineGray)
            context.restoreGState()
            lastMoonRect = moonRect
            return
        }
        
        // cosθ = 1 - 2f (θ in [0, π])
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta) // ellipse semi-minor / radius
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(2.0, rawEllipseWidth) // clamp
        let ellipseHeight = 2.0 * r
        let ellipseRect = CGRect(x: center.x - ellipseWidth / 2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: ellipseHeight)
        
        let isCrescent = f < 0.5
        let lightOnRight = moon.waxing
        
        if debugMoon, frameCounter % debugMoonLogEveryNFrames == 0 {
            os_log("MoonGeom frame=%{public}d f=%.4f waxing=%{public}@ cosθ=%.4f minorScale=%.4f rawEw=%.3f ew=%.3f r=%.1f crescent=%{public}@ centerX=%.3f",
                   log: log,
                   type: .debug,
                   frameCounter,
                   f,
                   lightOnRight ? "true" : "false",
                   cosTheta,
                   minorScale,
                   rawEllipseWidth,
                   ellipseWidth,
                   r,
                   isCrescent ? "true" : "false",
                   center.x)
        }
        
        // Base disc
        if isCrescent {
            context.setFillColor(darkGray)
        } else {
            context.setFillColor(lightGray)
        }
        context.addEllipse(in: moonRect)
        context.fillPath()
        
        // Overlay (crescent or gibbous shadow)
        if debugDisableAAOverlayPhase {
            context.saveGState()
            context.setAllowsAntialiasing(false)
            context.setShouldAntialias(false)
        }
        
        if isCrescent {
            addCrescentOverlay(context: context,
                               moonRect: moonRect,
                               ellipseRect: ellipseRect,
                               overlayColor: lightGray,
                               baseColor: darkGray,
                               lightOnRight: lightOnRight)
        } else {
            addGibbousShadow(context: context,
                             moonRect: moonRect,
                             ellipseRect: ellipseRect,
                             overlayColor: darkGray,
                             baseColor: lightGray,
                             lightOnRight: lightOnRight)
        }
        
        if debugDisableAAOverlayPhase {
            context.restoreGState() // restores antialiasing state
        }
        
        // Diagnostic overlays
        if debugMoon && debugMoonDrawOverlays {
            drawMoonDebugOverlays(context: context,
                                  moonRect: moonRect,
                                  ellipseRect: ellipseRect,
                                  lightOnRight: lightOnRight,
                                  isCrescent: isCrescent)
        }
        
        strokeLimb(context: context, rect: moonRect, outline: outlineGray)
        context.restoreGState()
        
        lastMoonRect = moonRect
    }
    
    // Crescent overlay (f < 0.5):
    // Fill illuminated side half-plane, carve interior ellipse back to base color.
    private func addCrescentOverlay(context: CGContext,
                                    moonRect: CGRect,
                                    ellipseRect: CGRect,
                                    overlayColor: CGColor,
                                    baseColor: CGColor,
                                    lightOnRight: Bool) {
        context.saveGState()
        context.addEllipse(in: moonRect)
        context.clip()
        
        let r = moonRect.width / 2.0
        let centerX = moonRect.midX
        let targetRightSide = lightOnRight
        // Slightly expand halfRect by 0.5 px across the center to promote overlap (reduces seam risk).
        let halfRect: CGRect
        if targetRightSide {
            halfRect = CGRect(x: centerX - 0.5,
                              y: moonRect.minY,
                              width: r + 0.5,
                              height: moonRect.height)
        } else {
            halfRect = CGRect(x: centerX - r - 0.5,
                              y: moonRect.minY,
                              width: r + 0.5,
                              height: moonRect.height)
        }
        context.clip(to: halfRect)
        
        // Fill illuminated side
        context.setFillColor(overlayColor)
        context.fill(halfRect)
        
        // Carve interior ellipse to restore base (dark)
        context.setFillColor(baseColor)
        context.addEllipse(in: ellipseRect)
        context.fillPath()
        
        context.restoreGState()
    }
    
    // Gibbous shadow (f > 0.5):
    // Fill dark side half-plane, carve interior ellipse back to base light color,
    // leaving outer sliver dark.
    private func addGibbousShadow(context: CGContext,
                                  moonRect: CGRect,
                                  ellipseRect: CGRect,
                                  overlayColor: CGColor,
                                  baseColor: CGColor,
                                  lightOnRight: Bool) {
        context.saveGState()
        context.addEllipse(in: moonRect)
        context.clip()
        
        let r = moonRect.width / 2.0
        let centerX = moonRect.midX
        let darkRightSide = !lightOnRight
        let halfRect: CGRect
        if darkRightSide {
            halfRect = CGRect(x: centerX - 0.5,
                              y: moonRect.minY,
                              width: r + 0.5,
                              height: moonRect.height)
        } else {
            halfRect = CGRect(x: centerX - r - 0.5,
                              y: moonRect.minY,
                              width: r + 0.5,
                              height: moonRect.height)
        }
        context.clip(to: halfRect)
        
        // Fill dark side
        context.setFillColor(overlayColor)
        context.fill(halfRect)
        
        // Carve interior ellipse back to light
        context.setFillColor(baseColor)
        context.addEllipse(in: ellipseRect)
        context.fillPath()
        
        context.restoreGState()
    }
    
    // Draw diagnostics: ellipse outline, half-plane boundary line, center line,
    // and optionally ellipse final outline after carving.
    private func drawMoonDebugOverlays(context: CGContext,
                                       moonRect: CGRect,
                                       ellipseRect: CGRect,
                                       lightOnRight: Bool,
                                       isCrescent: Bool) {
        context.saveGState()
        context.setLineWidth(1.0)
        context.setShouldAntialias(true)
        
        // Center vertical line (cyan)
        let centerX = moonRect.midX
        let centerLine = CGMutablePath()
        centerLine.move(to: CGPoint(x: centerX, y: moonRect.minY))
        centerLine.addLine(to: CGPoint(x: centerX, y: moonRect.maxY))
        context.addPath(centerLine)
        context.setStrokeColor(CGColor(red: 0.0, green: 1.0, blue: 1.0, alpha: 0.6))
        context.strokePath()
        
        // Half-plane boundary (drawn slightly thicker in magenta)
        context.setLineWidth(1.0)
        if isCrescent {
            // Illuminated side
            let right = lightOnRight
            let boundaryX = right ? centerX - 0.5 : centerX - 0.5
            let hp = CGMutablePath()
            hp.move(to: CGPoint(x: boundaryX, y: moonRect.minY))
            hp.addLine(to: CGPoint(x: boundaryX, y: moonRect.maxY))
            context.addPath(hp)
            context.setStrokeColor(CGColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 0.6))
            context.strokePath()
        } else {
            // Dark side
            let darkRight = !lightOnRight
            let boundaryX = darkRight ? centerX - 0.5 : centerX - 0.5
            let hp = CGMutablePath()
            hp.move(to: CGPoint(x: boundaryX, y: moonRect.minY))
            hp.addLine(to: CGPoint(x: boundaryX, y: moonRect.maxY))
            context.addPath(hp)
            context.setStrokeColor(CGColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 0.6))
            context.strokePath()
        }
        
        // Terminator ellipse outline (yellow)
        context.addEllipse(in: ellipseRect)
        context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 0.8))
        context.strokePath()
        
        // Final ellipse outline (optional separate color)
        if debugDrawFinalEllipseOutline {
            context.addEllipse(in: ellipseRect.insetBy(dx: 0.0, dy: 0.0))
            context.setStrokeColor(CGColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.4))
            context.strokePath()
        }
        
        context.restoreGState()
    }
    
    private func strokeLimb(context: CGContext, rect: CGRect, outline: CGColor) {
        context.setStrokeColor(outline)
        context.setLineWidth(1.0)
        context.addEllipse(in: rect)
        context.strokePath()
    }
    
    func convertColor(color: Color) -> CGColor {
        return CGColor(red: CGFloat(color.red),
                       green: CGFloat(color.green),
                       blue: CGFloat(color.blue),
                       alpha: 1.0)
    }
    
    func drawSingleCircle(point: Point, radius: Int = 4, context: CGContext) {
        context.saveGState()
        let color = self.convertColor(color: point.color)
        context.setFillColor(color)
        let boundingRect = CGRect(x: point.xPos - radius, y: point.yPos - radius, width: radius * 2, height: radius * 2)
        context.addEllipse(in: boundingRect)
        context.drawPath(using: .fill)
        context.restoreGState()
    }
    
    func drawSinglePoint(point: Point, size: Int = 10, context: CGContext) {
        context.saveGState()
        let color = self.convertColor(color: point.color)
        context.setFillColor(color)
        context.fill(CGRect(x: point.xPos, y: point.yPos, width: starSize, height: size))
        context.restoreGState()
    }
}

