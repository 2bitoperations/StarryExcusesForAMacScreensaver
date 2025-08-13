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
    // Previous implementation used an even-odd fill of (ellipse + side rectangle).
    // That occasionally produced an unwanted second dark band because the
    // "outside ellipse" region on the chosen side could become disjoint
    // (especially for large ellipse widths near full / new).
    //
    // New approach eliminates even-odd path ambiguity:
    //  1. (Optional threshold) Draw full dark or full light disc for near new/full.
    //  2. For general phases, always start with a base disc:
    //       - f < 0.5: start dark; add illuminated crescent.
    //       - f > 0.5: start light; add dark sliver.
    //  3. To add the crescent/sliver we:
    //       - Clip to the circle.
    //       - Further clip to the half-plane (left or right half of disc) for the target side.
    //       - Fill the entire half-plane with the desired overlay color.
    //       - Draw the terminator ellipse again inside that clip with the base color to "carve back"
    //         the interior of the ellipse. This leaves only the outside-of-ellipse region on that
    //         side as the overlay (crescent or gibbous shadow) with no mirrored artifacts.
    //  4. Stroke outer limb.
    //
    // This yields a single clean bright/dark division without residual artifacts.
    //
    // Trail removal:
    //   Before drawing the new moon each frame, fill the previous moon's bounding
    //   rectangle with black to erase the prior moon (preventing trail artifacts).
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
        let ellipseWidth = max(0.0001, 2.0 * r * minorScale)
        let ellipseHeight = 2.0 * r
        let ellipseRect = CGRect(x: center.x - ellipseWidth / 2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: ellipseHeight)
        
        if f < 0.5 {
            // Waxing or waning crescent: start with dark disc
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            
            // Add illuminated crescent on illuminated side
            addTerminatorOverlay(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 overlayColor: lightGray,
                                 baseColor: darkGray,
                                 lightOnRight: moon.waxing,
                                 addingLight: true)
        } else {
            // Gibbous: start with light disc
            context.setFillColor(lightGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
            
            // Add dark sliver on dark side
            addTerminatorOverlay(context: context,
                                 moonRect: moonRect,
                                 ellipseRect: ellipseRect,
                                 overlayColor: darkGray,
                                 baseColor: lightGray,
                                 lightOnRight: moon.waxing,
                                 addingLight: false)
        }
        
        strokeLimb(context: context, rect: moonRect, outline: outlineGray)
        context.restoreGState()
        
        lastMoonRect = moonRect
    }
    
    // Adds the crescent or gibbous shadow overlay without using even-odd,
    // preventing mirrored artifacts:
    //
    // Sequence:
    //   Clip to circle.
    //   Clip to target half-plane (illuminated side if addingLight, else dark side).
    //   Fill that half with overlayColor.
    //   Draw ellipse with baseColor to "erase" inside of ellipse, leaving only
    //   the outside-of-ellipse part of the half-plane as the crescent/sliver.
    private func addTerminatorOverlay(context: CGContext,
                                      moonRect: CGRect,
                                      ellipseRect: CGRect,
                                      overlayColor: CGColor,
                                      baseColor: CGColor,
                                      lightOnRight: Bool,
                                      addingLight: Bool) {
        context.saveGState()
        // Clip to circle.
        context.addEllipse(in: moonRect)
        context.clip()
        
        let r = moonRect.width / 2.0
        let centerX = moonRect.midX
        
        // Determine which half-plane we will operate on.
        // If adding light, target illuminated side. Otherwise target dark side.
        let illuminatedRightSide = lightOnRight
        let targetRightSide = addingLight ? illuminatedRightSide : !illuminatedRightSide
        
        let halfRect: CGRect
        if targetRightSide {
            halfRect = CGRect(x: centerX,
                               y: moonRect.minY,
                               width: r,
                               height: moonRect.height)
        } else {
            halfRect = CGRect(x: centerX - r,
                               y: moonRect.minY,
                               width: r,
                               height: moonRect.height)
        }
        
        // Clip to half-plane
        context.clip(to: halfRect)
        
        // Fill entire half-plane with overlay color
        context.setFillColor(overlayColor)
        context.fill(halfRect)
        
        // Carve back inside ellipse with the base color to leave only outside-of-ellipse overlay
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

