//
//  SkylineDraw.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 4/29/19.
//  Copyright © 2019 2bitoperations. All rights reserved.
//

import Foundation

class SkylineDraw {
    let skyline: Skyline
    let context: CGContext
    
    init(skyline: Skyline, context: CGContext) {
        self.skyline = skyline
        self.context = context
    }
    
    func drawSingleFrame() {
        drawStars()
        drawBuildings()
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
    
    static func convertColor(color: Color) -> CGColor {
        return CGColor(red: CGFloat(color.red),
                       green: CGFloat(color.green),
                       blue: CGFloat(color.blue),
                       alpha: 1.0)
    }
    
    func drawSinglePoint(point: Point) {
        context.protectGState {
            let color = SkylineDraw.convertColor(color: point.color)
            context.setFillColor(color)
            context.fill(CGRect(x: point.xPos, y: point.yPos, width: 1, height: 1))
        }
    }
}
