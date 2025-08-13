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
        // Order: moon, stars, buildings, flasher
        drawMoon(context: context)
        drawStars(context: context)
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
    
    // MARK: - Moon Rendering
    
    func drawMoon(context: CGContext) {
        guard let moon = skyline.getMoon() else { return }
        let center = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let fraction = moon.illuminatedFraction
        
        let lightGray = CGColor(gray: 0.85, alpha: 1.0)
        let outlineGray = CGColor(gray: 0.6, alpha: 0.7)
        context.saveGState()
        
        if fraction <= Moon.newMoonThreshold {
            // Faint outline only
            context.setStrokeColor(outlineGray)
            context.setLineWidth(1.0)
            context.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r))
            context.strokePath()
            context.restoreGState()
            return
        }
        
        // Draw full illuminated base disc
        context.setFillColor(lightGray)
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        context.addEllipse(in: moonRect)
        context.fillPath()
        
        if fraction >= Moon.fullMoonThreshold {
            context.restoreGState()
            return
        }
        
        // Draw dark (shadow) disc to "punch out" correct phase
        let d = CGFloat(moon.shadowCenterOffset)
        let offsetSign: CGFloat = moon.waxing ? -1.0 : 1.0
        let shadowCenterX = center.x + offsetSign * d
        let shadowRect = CGRect(x: shadowCenterX - r, y: center.y - r, width: 2*r, height: 2*r)
        
        context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        context.addEllipse(in: shadowRect)
        context.fillPath()
        
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

