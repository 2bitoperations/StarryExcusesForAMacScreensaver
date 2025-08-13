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
    
    // Debug flags (disabled for normal operation)
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    
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
    
    // MARK: - Moon Rendering (no outline)
    //
    // We intentionally do NOT stroke the limb; the visible moon is defined
    // only by its light and dark regions (even for full / new phases).
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon() else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(max(0.0, min(1.0, moon.illuminatedFraction)))
        
        let lightGray = CGColor(gray: 0.85, alpha: 1.0)
        let darkGray  = CGColor(gray: 0.08, alpha: 1.0)
        
        let newThreshold: CGFloat = 0.005
        let fullThreshold: CGFloat = 0.995
        
        // Clear old moon
        if let prev = lastMoonRect {
            context.saveGState()
            context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
            context.fill(prev.insetBy(dx: -1, dy: -1))
            context.restoreGState()
        }
        
        context.saveGState()
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        if f <= newThreshold {
            // New moon (dark disc only)
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            context.restoreGState()
            lastMoonRect = moonRect
            return
        } else if f >= fullThreshold {
            // Full moon (light disc only)
            context.setFillColor(lightGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            context.restoreGState()
            lastMoonRect = moonRect
            return
        }
        
        // Orthographic terminator geometry
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(0.5, rawEllipseWidth)
        let ellipseHeight = 2.0 * r
        let ellipseRect = CGRect(x: center.x - ellipseWidth / 2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: ellipseHeight)
        
        let isCrescent = f < 0.5
        let lightOnRight = moon.waxing
        
        if debugMoon, frameCounter % debugMoonLogEveryNFrames == 0 {
            os_log("MoonGeom frame=%{public}d f=%.4f waxing=%{public}@ cosθ=%.4f ew=%.3f",
                   log: log,
                   type: .debug,
                   frameCounter,
                   f,
                   lightOnRight ? "true" : "false",
                   cosTheta,
                   ellipseWidth)
        }
        
        // Base disc
        let baseColor = isCrescent ? darkGray : lightGray
        context.setFillColor(baseColor)
        context.addEllipse(in: moonRect)
        context.fillPath()
        
        // Overlay half-plane with overlap then carve ellipse
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
            // Carve interior ellipse back to dark
            context.setFillColor(baseColor)
            context.addEllipse(in: ellipseRect)
            context.fillPath()
        } else {
            // Gibbous: dark on dark side (opposite illuminated side)
            let overlayColor = darkGray
            if lightOnRight { // dark on left
                sideRect = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            } else { // dark on right
                sideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            }
            context.setFillColor(overlayColor)
            context.fill(sideRect)
            // Carve interior ellipse back to light
            context.setFillColor(baseColor)
            context.addEllipse(in: ellipseRect)
            context.fillPath()
        }
        context.restoreGState()
        
        context.restoreGState()
        lastMoonRect = moonRect
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

