//
//  StarryExcusesView.swift
//
//  Original Code:
//  Created by Marcus Kida on 17.12.17.
//  Copyright © 2017 Marcus Kida. All rights reserved.
//
//  Modifications:
//  Modified by Andrew Malota (2bitoperations) on 2018-12
//  Copyright © 2018 Andrew Malota. All rights reserved.
//
//  Original code and modifications released under the MIT license.
//

import ScreenSaver
import Foundation
import os

open class StarryExcusesForAMacScreensaverView: ScreenSaverView {
    private var log: OSLog?
    
    convenience init() {
        self.init(frame: .zero, isPreview: false)
        initialize()
    }
    
    override init!(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        initialize()
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        initialize()
    }
    
    override open var configureSheet: NSWindow? {
        return nil
    }
    
    override open var hasConfigureSheet: Bool {
        return false
    }
    
    override open func animateOneFrame() {
        //self.skyDraw?.drawSingleFrame()
    }
    
    override open func draw(_ rect: NSRect) {
        super.draw(rect)
        
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        
        guard let log = self.log else {
            return
        }
        
        os_log("invoking skyline view init", log: log, type: .info)
        let skyline = Skyline(screenXMax: context.width, screenYMax: context.height)
        //let skyDraw = SkylineDraw(skyline: skyline, context: context)
        //self.skyDraw?.drawSingleFrame()
    }
    
    private func initialize() {
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "View")
        animationTimeInterval = 0.5
    }
}
