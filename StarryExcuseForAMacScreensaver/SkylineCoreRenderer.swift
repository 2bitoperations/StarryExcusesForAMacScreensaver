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
    
    // Dark region brightness factor (applied to texture)
    private let darkBrightness: CGFloat = 0.15
    
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
    
    // MARK: - Moon Rendering (textured, no outline)
    //
    // Uses low-res grayscale texture (nearest neighbor) scaled to moon diameter.
    // Light / dark regions rendered via drawing texture at full brightness
    // and/or darkened (overlay black with alpha) for shadowed portion.
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon() else { return }
        guard let texture = moon.textureImage else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(max(0.0, min(1.0, moon.illuminatedFraction)))
        
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
        context.interpolationQuality = .none // preserve pixelated texture
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        if f <= newThreshold {
            // Entire disc dark
            drawTexture(context: context, image: texture, in: moonRect, brightness: darkBrightness, clipToCircle: true)
            context.restoreGState()
            lastMoonRect = moonRect
            return
        } else if f >= fullThreshold {
            // Entire disc bright
            drawTexture(context: context, image: texture, in: moonRect, brightness: 1.0, clipToCircle: true)
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
        
        // Base disc texture (dark for crescent, bright for gibbous)
        let baseBrightness: CGFloat = isCrescent ? darkBrightness : 1.0
        drawTexture(context: context, image: texture, in: moonRect, brightness: baseBrightness, clipToCircle: true)
        
        // Overlay half-plane with opposite brightness and carve ellipse interior
        context.saveGState()
        // Clip to lunar disc first
        context.addEllipse(in: moonRect)
        context.clip()
        
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        let sideRect: CGRect
        if isCrescent {
            // Add bright on illuminated side
            if lightOnRight {
                sideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            } else {
                sideRect = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            }
            // Brighten sideRect area
            context.saveGState()
            context.clip(to: sideRect)
            drawTexture(context: context, image: texture, in: moonRect, brightness: 1.0, clipToCircle: false)
            context.restoreGState()
            
            // Carve ellipse interior back to dark brightness
            context.saveGState()
            context.addEllipse(in: ellipseRect)
            context.clip()
            drawTexture(context: context, image: texture, in: moonRect, brightness: darkBrightness, clipToCircle: false)
            context.restoreGState()
        } else {
            // Gibbous: darken dark side
            if lightOnRight { // dark on left
                sideRect = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            } else { // dark on right
                sideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            }
            // Darken sideRect
            context.saveGState()
            context.clip(to: sideRect)
            drawTexture(context: context, image: texture, in: moonRect, brightness: darkBrightness, clipToCircle: false)
            context.restoreGState()
            
            // Carve ellipse interior back to bright
            context.saveGState()
            context.addEllipse(in: ellipseRect)
            context.clip()
            drawTexture(context: context, image: texture, in: moonRect, brightness: 1.0, clipToCircle: false)
            context.restoreGState()
        }
        context.restoreGState() // end overlay ops
        
        context.restoreGState()
        lastMoonRect = moonRect
    }
    
    // Draw the grayscale texture scaled into rect with brightness factor.
    // If clipToCircle is true, clips to a circle matching rect first.
    private func drawTexture(context: CGContext,
                             image: CGImage,
                             in rect: CGRect,
                             brightness: CGFloat,
                             clipToCircle: Bool) {
        context.saveGState()
        context.interpolationQuality = .none
        if clipToCircle {
            context.addEllipse(in: rect)
            context.clip()
        }
        context.draw(image, in: rect)
        if brightness < 0.999 {
            // Darken by overlaying black with alpha = 1 - brightness
            let alpha = min(1.0, max(0.0, 1.0 - brightness))
            if alpha > 0 {
                context.setFillColor(CGColor(gray: 0.0, alpha: alpha))
                context.fill(rect)
            }
        } else if brightness > 1.0 {
            // (Not used, but could implement brighten via screen blend)
        }
        context.restoreGState()
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

