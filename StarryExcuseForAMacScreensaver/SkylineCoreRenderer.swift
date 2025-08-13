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
    
    // MARK: - Moon Rendering (curved terminator via overlapping circle)
    //
    // We draw a full light disc, then overlay a dark disc of the same radius
    // horizontally offset based on illuminated fraction:
    //   offset d = 2 * r * f   (f in [0,1])
    // Waxing: dark disc shifted left  (illumination on right)
    // Waning: dark disc shifted right (illumination on left)
    // This produces a circular (curved) terminator with correct qualitative shape.
    // Always stroke limb after fills. Stars are underneath (drawn earlier).
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon() else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let f = CGFloat(max(0.0, min(1.0, moon.illuminatedFraction)))
        
        let lightGray = CGColor(gray: 0.85, alpha: 1.0)
        let darkGray  = CGColor(gray: 0.08, alpha: 1.0)
        let outlineGray = CGColor(gray: 0.6, alpha: 1.0)
        
        context.saveGState()
        
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        // If there is any illumination, start with full light disc
        if f > 0.0 {
            context.setFillColor(lightGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
        } else {
            // Pure new moon: fill dark disc (will get outline below)
            context.setFillColor(darkGray)
            context.addEllipse(in: moonRect)
            context.fillPath()
        }
        
        // If not full, overlay dark disc to carve the shadow portion
        if f < 1.0 {
            let d = 2.0 * r * f   // simple proportional offset
            let offsetSign: CGFloat = moon.waxing ? -1.0 : 1.0
            let shadowCenterX = center.x + offsetSign * d
            let shadowRect = CGRect(x: shadowCenterX - r, y: center.y - r, width: 2*r, height: 2*r)
            context.setFillColor(darkGray)
            context.addEllipse(in: shadowRect)
            context.fillPath()
        }
        
        // Stroke lunar limb
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

