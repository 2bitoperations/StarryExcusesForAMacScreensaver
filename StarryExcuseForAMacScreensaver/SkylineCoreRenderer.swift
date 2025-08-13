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
    
    // MARK: - Moon Debug / Instrumentation Flags (all off by default for clean output)
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    private let debugMoonDrawOverlays = false
    private let debugDisableAAOverlayPhase = false
    private let debugDrawFinalEllipseOutline = false
    
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
        frameCounter &+= 1
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
    
    // MARK: - Moon Rendering (Option A: half-plane overlap + ellipse carve)
    //
    // Approach:
    //  1. Base disc: dark (crescent) or light (gibbous).
    //  2. Clip to circle, fill the relevant side half-plane (illuminated side for crescent;
    //     dark side for gibbous) with overlay color. The half-plane rectangle overlaps
    //     the center line by 1 pixel to avoid a seam.
    //  3. Carve the interior of the ellipse using the base color, leaving only the outer
    //     crescent / dark sliver.
    //  4. Stroke the limb.
    //
    // This returns to a simpler and stable construction, removing artifacts introduced
    // by restricted rectangles and even-odd sliver variants.
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon() else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(max(0.0, min(1.0, moon.illuminatedFraction)))
        
        let lightGray = CGColor(gray: 0.85, alpha: 1.0)
        let darkGray  = CGColor(gray: 0.08, alpha: 1.0)
        let outlineGray = CGColor(gray: 0.6, alpha: 1.0)
        
        // Thresholds for pure new/full handling
        let newThreshold: CGFloat = 0.005
        let fullThreshold: CGFloat = 0.995
        
        // Erase previous moon (if any) to prevent trail artifacts.
        if let prev = lastMoonRect {
            context.saveGState()
            context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
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
        
        // Phase geometry (orthographic projection ellipse)
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        // Minimum width clamp to avoid degeneracy (treat near quarter as a very narrow ellipse)
        let ellipseWidth = max(0.5, rawEllipseWidth)
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
        let baseColor = isCrescent ? darkGray : lightGray
        context.setFillColor(baseColor)
        context.addEllipse(in: moonRect)
        context.fillPath()
        
        if debugDisableAAOverlayPhase {
            context.saveGState()
            context.setAllowsAntialiasing(false)
            context.setShouldAntialias(false)
        }
        
        // Overlay half-plane with 1 px overlap past the center line
        context.saveGState()
        context.addEllipse(in: moonRect)
        context.clip()
        
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        let sideRect: CGRect
        if isCrescent {
            // Add light on illuminated side
            let overlayColor = lightGray
            if lightOnRight {
                sideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            } else {
                sideRect = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            }
            context.setFillColor(overlayColor)
            context.fill(sideRect)
            // Carve interior ellipse back to base (dark)
            context.setFillColor(baseColor)
            context.addEllipse(in: ellipseRect)
            context.fillPath()
        } else {
            // Gibbous: add dark on dark side (opposite illuminated side)
            let overlayColor = darkGray
            if lightOnRight { // dark on left
                sideRect = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            } else { // dark on right
                sideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            }
            context.setFillColor(overlayColor)
            context.fill(sideRect)
            // Carve interior ellipse back to base (light)
            context.setFillColor(baseColor)
            context.addEllipse(in: ellipseRect)
            context.fillPath()
        }
        context.restoreGState()
        
        if debugDisableAAOverlayPhase {
            context.restoreGState()
        }
        
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
    
    // Optional debug overlays
    private func drawMoonDebugOverlays(context: CGContext,
                                       moonRect: CGRect,
                                       ellipseRect: CGRect,
                                       lightOnRight: Bool,
                                       isCrescent: Bool) {
        context.saveGState()
        context.setLineWidth(1.0)
        context.setShouldAntialias(true)
        
        let centerX = moonRect.midX
        
        // Center vertical line (cyan)
        let centerLine = CGMutablePath()
        centerLine.move(to: CGPoint(x: centerX, y: moonRect.minY))
        centerLine.addLine(to: CGPoint(x: centerX, y: moonRect.maxY))
        context.addPath(centerLine)
        context.setStrokeColor(CGColor(red: 0.0, green: 1.0, blue: 1.0, alpha: 0.6))
        context.strokePath()
        
        // Terminator ellipse outline (yellow)
        context.addEllipse(in: ellipseRect)
        context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 0.8))
        context.strokePath()
        
        if debugDrawFinalEllipseOutline {
            context.addEllipse(in: ellipseRect)
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

