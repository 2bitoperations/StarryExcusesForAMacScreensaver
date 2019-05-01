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

class StarryExcuseForAView: ScreenSaverView {
    private var log: OSLog?
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    
    private func setupInternal() {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        
        if self.log == nil {
            self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        }
        os_log("invoking skyline view setup internal", log: self.log!, type: .info)
        
        if self.skyline == nil || skyline?.width != context.width {
            self.skyline = Skyline(screenXMax: context.width, screenYMax: context.height)
            self.skylineRenderer = SkylineCoreRenderer(skyline: self.skyline!, context: context)
            os_log("created skyline", log: self.log!, type: .info)
            self.animationTimeInterval = 0.005
        }
    }
    
    override open func animateOneFrame() {
        self.setupInternal()
        self.skylineRenderer?.drawSingleFrame()
    }
    
    override open func draw(_ rect: NSRect) {
        super.draw(rect)
        
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        //context.setFillColor(CGColor(red:1.0, green:0.0, blue: 0.0, alpha: 1.0))
        //rect.fill()
        
        self.setupInternal()
        skylineRenderer?.drawSingleFrame()
    }
}
