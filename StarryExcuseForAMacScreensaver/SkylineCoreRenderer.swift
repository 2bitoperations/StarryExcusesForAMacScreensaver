//
//  SkylineCoreRenderer.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 4/30/19.
//  Copyright © 2019 Andrew Malota. All rights reserved.
//

import Foundation
import os
import ScreenSaver

class SkylineCoreRenderer {
    let skyline: Skyline
    let context: CGContext
    let log: OSLog
    let starSize = 10
    
    init(skyline: Skyline, context: CGContext, log: OSLog) {
        self.skyline = skyline
        self.context = context
        self.log = log
    }
    
    func drawSingleFrame() {
        drawTestLine()
        drawStars()
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
            self.drawSinglePoint(point: star)
        }
    }
    
    func drawBuildings() {
        for _ in 0...skyline.buildingLightsPerUpdate {
            let light = skyline.getSingleBuildingPoint()
            self.drawSinglePoint(point: light)
        }
    }
    
    func convertColor(color: Color) -> CGColor {
        return CGColor(red: CGFloat(color.red),
                       green: CGFloat(color.green),
                       blue: CGFloat(color.blue),
                       alpha: 1.0)
    }
    
    func drawSinglePoint(point: Point) {
        context.saveGState()
        let color = self.convertColor(color: point.color)
        context.setFillColor(color)
        context.fill(CGRect(x: point.xPos, y: point.yPos, width: starSize, height: starSize))
        context.restoreGState()
    }
}

