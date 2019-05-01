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
    
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        os_log("start skyline init")
        
        if self.log == nil {
            self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        }
        
        self.animationTimeInterval = TimeInterval(1.0)
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
        super.animateOneFrame()
        os_log("skyline init animate one frame", log: self.log!, type: .fault)
        guard let _ = self.skylineRenderer else {
            os_log("skyline init animate one frame exit skyline not init", log: self.log!, type: .fault)
            return
        }
        self.skylineRenderer?.drawSingleFrame()
    }
    
    override open func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            os_log("skyline init draw abort, context couldn't be fetched", log: self.log!, type: .fault)
            return
        }
        
        os_log("invoking skyline init", log: self.log!, type: .fault)
        self.skyline = Skyline(screenXMax: context.width,
                               screenYMax: context.height,
                               starsPerUpdate: 120)
        self.skylineRenderer = SkylineCoreRenderer(skyline: self.skyline!, context: context, log: self.log!)
        self.startAnimation()
        super.draw(rect)
        os_log("skyline init created skyline", log: self.log!, type: .fault)
    }
}
