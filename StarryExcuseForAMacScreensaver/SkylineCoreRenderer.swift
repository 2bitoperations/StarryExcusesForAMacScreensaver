//
//  SkylineCoreRenderer.swift
//  StarryExcuseForAMacScreensaver
//

import Foundation
import os
import ScreenSaver
import CoreGraphics

// Renders ONLY the evolving star field, building lights, and flasher.
// The moon has been decoupled and is now rendered in MoonLayerRenderer
// so that it "floats" above the accumulated star field.
class SkylineCoreRenderer {
    let skyline: Skyline
    let log: OSLog
    let starSize = 1
    let traceEnabled: Bool
    
    private var frameCounter: Int = 0
    
    init(skyline: Skyline, log: OSLog, traceEnabled: Bool) {
        self.skyline = skyline
        self.log = log
        self.traceEnabled = traceEnabled
    }
    
    func resetFrameCounter() { frameCounter = 0 }
    
    func drawSingleFrame(context: CGContext) {
        if traceEnabled {
            os_log("drawing base frame (no moon)", log: log, type: .debug)
        }
        frameCounter &+= 1
        drawStars(context: context)
        drawBuildings(context: context)
        drawFlasher(context: context)
    }
    
    private func drawStars(context: CGContext) {
        for _ in 0...skyline.starsPerUpdate {
            let star = skyline.getSingleStar()
            drawSinglePoint(point: star, size: starSize, context: context)
        }
    }
    
    private func drawBuildings(context: CGContext) {
        for _ in 0...skyline.buildingLightsPerUpdate {
            let light = skyline.getSingleBuildingPoint()
            drawSinglePoint(point: light, size: starSize, context: context)
        }
    }
    
    private func drawFlasher(context: CGContext) {
        guard let flasher = skyline.getFlasher() else { return }
        drawSingleCircle(point: flasher, radius: skyline.flasherRadius, context: context)
    }
    
    // MARK: - Primitive Drawing
    
    private func convertColor(color: Color) -> CGColor {
        CGColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1.0)
    }
    
    private func drawSingleCircle(point: Point, radius: Int = 4, context: CGContext) {
        context.saveGState()
        context.setFillColor(convertColor(color: point.color))
        let rect = CGRect(x: point.xPos - radius, y: point.yPos - radius, width: radius * 2, height: radius * 2)
        context.addEllipse(in: rect)
        context.drawPath(using: .fill)
        context.restoreGState()
    }
    
    private func drawSinglePoint(point: Point, size: Int = 10, context: CGContext) {
        context.saveGState()
        context.setFillColor(convertColor(color: point.color))
        context.fill(CGRect(x: point.xPos, y: point.yPos, width: starSize, height: size))
        context.restoreGState()
    }
}
