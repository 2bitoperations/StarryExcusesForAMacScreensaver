//
//  SkylineCoreRenderer.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 4/30/19.
//  Copyright © 2019 Andrew Malota. All rights reserved.
//

import Foundation
import os
import AppKit

class SkylineCoreRenderer {
    let skyline: Skyline
    let context: NSGraphicsContext
    
    init(skyline: Skyline, context: NSGraphicsContext) {
        self.skyline = skyline
        self.context = context
    }
    
    func drawSingleFrame() {
        drawTestLine()
        //drawStars()
        //drawBuildings()
    }
    
    func drawTestLine() {
        for xIndex in 0...skyline.width {
            let point = Point(xPos: xIndex, yPos: 10 + xIndex, color: Color(red: 0.0, green: 0.0, blue: 1.0))
            drawSinglePoint(point: point)
        }
    }
    
    func drawStars() {
        for _ in 0...skyline.starsPerUpdate {
            let star = skyline.getSingleStar()
            drawSinglePoint(point: star)
        }
    }
    
    func drawBuildings() {
        for _ in 0...skyline.buildingLightsPerUpdate {
            let light = skyline.getSingleBuildingPoint()
            drawSinglePoint(point: light)
        }
    }
    
    func convertColor(color: Color) -> NSColor {
        return NSColor(red: CGFloat(color.red),
                       green: CGFloat(color.green),
                       blue: CGFloat(color.blue),
                       alpha: 1.0)
    }
    
    func drawSinglePoint(point: Point) {
        context.saveGraphicsState()
        let color = self.convertColor(color: point.color)
        color.setFill()
        let rect = NSRect(x: point.xPos, y: point.yPos, width: 10, height: 10)
        rect.fill()
        context.restoreGraphicsState()
    }
}

