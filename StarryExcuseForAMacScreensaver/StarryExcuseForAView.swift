//
//  StarryExcuseForAView.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 4/30/19.
//  Copyright © 2019 Andrew Malota. All rights reserved.
//

import ScreenSaver
import Foundation
import os
import CoreGraphics

class StarryExcuseForAView: ScreenSaverView {
    private var log: OSLog?
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var bitmapBuffer: NSBitmapImageRep?
    
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        os_log("start skyline init")
        
        if self.log == nil {
            self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        }
        
        self.animationTimeInterval = TimeInterval(0.1)
    }
    
    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
    }
    
    override func startAnimation() {
        super.startAnimation()
        
    }
    
    override func stopAnimation() {
        super.stopAnimation()
    }

    
    override open func animateOneFrame() {
        // WOW osx graphics devel is tedious... apparently mojave broke animation contexts...
        // https://github.com/lionheart/openradar-mirror/issues/20659
        if (bitmapBuffer == nil) {
            bitmapBuffer = self.bitmapImageRepForCachingDisplay(in: self.bounds)
            let context = NSGraphicsContext(bitmapImageRep: self.bitmapBuffer!)?.cgContext
            context?.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
            let bufferSize = (bitmapBuffer?.size)!
            let rect = CGRect(origin: CGPoint(x: 0, y: 0), size: bufferSize)
            context?.fill(rect)
        }
        let context = NSGraphicsContext(bitmapImageRep: self.bitmapBuffer!)?.cgContext
        self.skylineRenderer?.drawSingleFrame(context: context!)
        context?.flush()
        self.needsDisplay = true
    }
    
    override open func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            os_log("skyline init draw abort, context couldn't be fetched", log: self.log!, type: .fault)
            return
        }
        
        if self.skyline == nil {
            do {
                self.skyline = try Skyline(screenXMax: context.width,
                                       screenYMax: context.height,
                                       starsPerUpdate: 120,
                                       log: self.log!)
                self.skylineRenderer = SkylineCoreRenderer(skyline: self.skyline!, log: self.log!)
            } catch {
                let msg = "\(error)"
                os_log("unable to init skyline %{public}@", log: self.log!, type: .fault, msg)
            }
            super.draw(rect)
            os_log("skyline init created skyline", log: self.log!, type: .fault)
        }
        
        if (bitmapBuffer != nil && bitmapBuffer?.cgImage != nil) {
            let cgImage = bitmapBuffer!.cgImage!
            context.draw(cgImage, in: rect)
        }
        
    }
}
