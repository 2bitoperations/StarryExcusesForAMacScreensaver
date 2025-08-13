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
        // Order updated so stars NEVER draw over the moon:
        // stars, moon, buildings, flasher
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
    
    // MARK: - Moon Rendering (vertical chord approximation)
    //
    // We render a more "optical" looking phase silhouette while accepting
    // some area inaccuracy:
    // 1. Fill entire disc with near-black dark side color.
    // 2. Compute a vertical chord position and fill the illuminated segment
    //    with light gray. The chord is straight at half phase and moves
    //    toward the limb for crescents/gibbous, matching the classic
    //    80's monochrome style.
    // 3. Always stroke the full lunar limb.
    //
    // Stars are drawn BEFORE the moon, so none appear on top of either
    // illuminated or dark portions.
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon() else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = max(0.0, min(1.0, moon.illuminatedFraction))
        
        let darkGray = CGColor(gray: 0.08, alpha: 1.0)     // almost-black
        let lightGray = CGColor(gray: 0.85, alpha: 1.0)
        let outlineGray = CGColor(gray: 0.6, alpha: 1.0)
        
        context.saveGState()
        
        // Full disc (dark side base)
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        context.setFillColor(darkGray)
        context.addEllipse(in: moonRect)
        context.fillPath()
        
        // Illuminated segment
        if f > 0.0005 { // draw only if some illumination
            context.saveGState()
            // Clip to the moon circle so we only fill inside limb
            context.addEllipse(in: moonRect)
            context.clip()
            
            // Compute vertical chord boundaries.
            // We map fraction to linear width for simplicity (visual > area accuracy).
            // width = 2r * f
            let fullDiameter = 2.0 * r
            let litWidth = CGFloat(f) * fullDiameter
            if moon.waxing {
                // Waxing: light on the right
                let xStart = center.x + r - litWidth
                let litRect = CGRect(x: xStart,
                                     y: center.y - r,
                                     width: litWidth,
                                     height: fullDiameter)
                context.setFillColor(lightGray)
                context.fill(litRect)
            } else {
                // Waning: light on the left
                let xEnd = center.x - r + litWidth
                let litRect = CGRect(x: center.x - r,
                                     y: center.y - r,
                                     width: litWidth,
                                     height: fullDiameter)
                context.setFillColor(lightGray)
                context.fill(litRect)
            }
            context.restoreGState()
        }
        
        // Always stroke the outer limb
        context.setStrokeColor(outlineGray)
        context.setLineWidth(1.0)
        context.addEllipse(in: moonRect)
        context.strokePath()
        
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

