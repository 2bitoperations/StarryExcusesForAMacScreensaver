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
    
    init(skyline: Skyline, log: OSLog, traceEnabled: Bool) {
        self.skyline = skyline
        self.log = log
        self.traceEnabled = traceEnabled
    }
    
    func drawSingleFrame(context: CGContext) {
        if (traceEnabled) {
            os_log("drawing single frame", log: self.log, type: .debug)
        }
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
    // Improvement:
    //  - Mitigate flickering narrow vertical chord by enforcing a minimum ellipse width (>= 2px),
    //    preventing sub-pixel degeneracy when the phase is near first/last quarter.
    //  - Direction now deterministic (handled in Moon.swift).
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
            // Nearly new: dark disc + outline
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            strokeLimb(context: context, rect: moonRect, outline: outlineGray)
            context.restoreGState()
            lastMoonRect = moonRect
            return
        } else if f >= fullThreshold {
            // Nearly full: light disc + outline
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
        // Enforce a minimum ellipse width (2px) to suppress sub-pixel flicker.
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(2.0, rawEllipseWidth)
        let ellipseHeight = 2.0 * r
        let ellipseRect = CGRect(x: center.x - ellipseWidth / 2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: ellipseHeight)
        
        if f < 0.5 {
            // Crescent: start with dark disc
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            
            // Add illuminated crescent outside ellipse on illuminated side
            addCrescentOverlay(context: context,
                               moonRect: moonRect,
                               ellipseRect: ellipseRect,
                               overlayColor: lightGray,
                               baseColor: darkGray,
                               lightOnRight: moon.waxing)
        } else {
            // Gibbous: start with light disc
            context.setFillColor(lightGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            
            // Add dark sliver outside ellipse on dark side (current approximation).
            addGibbousShadow(context: context,
                             moonRect: moonRect,
                             ellipseRect: ellipseRect,
                             overlayColor: darkGray,
                             baseColor: lightGray,
                             lightOnRight: moon.waxing)
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
        // Illumination side
        let targetRightSide = lightOnRight
        let halfRect = CGRect(x: targetRightSide ? centerX : centerX - r,
                              y: moonRect.minY,
                              width: r,
                              height: moonRect.height)
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
    // leaving outer sliver dark. (Approximation consistent with crescent method.)
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
        // Dark side is opposite illuminated side
        let darkRightSide = !lightOnRight
        let halfRect = CGRect(x: darkRightSide ? centerX : centerX - r,
                              y: moonRect.minY,
                              width: r,
                              height: moonRect.height)
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

