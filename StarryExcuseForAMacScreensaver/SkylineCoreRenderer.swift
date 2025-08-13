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
    
    // MARK: - Moon Rendering (orthographic projection with elliptical terminator)
    //
    // We approximate an orthographic view of a sun‑lit sphere:
    //  - The lunar limb is a circle of radius r.
    //  - The day/night terminator projects to an ellipse centered on the disc.
    //  - Major (vertical) axis: 2r. Minor (horizontal) axis: 2r * |cos θ|.
    //    Where cos θ = 1 - 2f and f is illuminatedFraction in [0,1].
    //    (Because f = (1 - cos θ)/2 => cos θ = 1 - 2f.)
    //  - For f < 0.5 (crescent): illuminated region is the portion of the circle
    //    OUTSIDE the ellipse on the illuminated side.
    //  - For f > 0.5 (gibbous): dark region is the portion of the circle
    //    OUTSIDE the ellipse on the dark side.
    // We construct these shapes using an even‑odd fill combining the ellipse
    // with a side rectangle, under a clip of the lunar circle, avoiding
    // gradients for a crisp 80's monochrome feel.
    //
    // Thresholds avoid degenerate geometry near new/full.
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
        
        context.saveGState()
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        if f <= newThreshold {
            // Nearly new: dark disc + outline
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            strokeLimb(context: context, rect: moonRect, outline: outlineGray)
            context.restoreGState()
            return
        } else if f >= fullThreshold {
            // Nearly full: light disc + outline
            context.setFillColor(lightGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            strokeLimb(context: context, rect: moonRect, outline: outlineGray)
            context.restoreGState()
            return
        }
        
        // Compute cosine of phase angle
        let cosTheta = 1.0 - 2.0 * f  // matches f = (1 - cosθ)/2
        let minorScale = abs(cosTheta) // in [0,1]
        let ellipseWidth = max(0.0001, 2.0 * r * minorScale)
        let ellipseHeight = 2.0 * r   // vertical major axis
        let ellipseRect = CGRect(x: center.x - ellipseWidth / 2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: ellipseHeight)
        
        if f < 0.5 {
            // Crescent: start with dark disc, add illuminated region (outside ellipse)
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            
            drawOutsideEllipseSide(context: context,
                                   circleRect: moonRect,
                                   ellipseRect: ellipseRect,
                                   fillColor: lightGray,
                                   lightOnRight: moon.waxing)
        } else {
            // Gibbous: start with full light disc, add small dark region (outside ellipse)
            context.setFillColor(lightGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            
            drawOutsideEllipseSide(context: context,
                                   circleRect: moonRect,
                                   ellipseRect: ellipseRect,
                                   fillColor: darkGray,
                                   lightOnRight: moon.waxing,
                                   isDarkRegion: true)
        }
        
        // Outline
        strokeLimb(context: context, rect: moonRect, outline: outlineGray)
        context.restoreGState()
    }
    
    // Draw region of the circle that lies outside the ellipse on one side.
    // Uses even-odd fill: ellipse + side rectangle clipped to circle.
    // lightOnRight indicates where illumination resides.
    // If isDarkRegion is true, we are adding shadow for gibbous phases (opposite side).
    private func drawOutsideEllipseSide(context: CGContext,
                                        circleRect: CGRect,
                                        ellipseRect: CGRect,
                                        fillColor: CGColor,
                                        lightOnRight: Bool,
                                        isDarkRegion: Bool = false) {
        context.saveGState()
        // Clip to the lunar disc boundary.
        context.addEllipse(in: circleRect)
        context.clip()
        
        // Determine which side rectangle to use.
        let illuminatedRightSide = lightOnRight
        let targetRightSide = isDarkRegion ? !illuminatedRightSide : illuminatedRightSide
        
        let r = circleRect.width / 2.0
        let centerX = circleRect.midX
        let rectX: CGFloat = targetRightSide ? centerX : centerX - r
        let sideRect = CGRect(x: rectX,
                              y: circleRect.minY,
                              width: r,
                              height: circleRect.height)
        
        // Build even-odd path: ellipse + side rectangle
        let path = CGMutablePath()
        path.addEllipse(in: ellipseRect)
        path.addRect(sideRect)
        
        context.addPath(path)
        context.setFillColor(fillColor)
        // Use .eoFill drawing mode for even-odd rule
        context.drawPath(using: .eoFill)
        
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

