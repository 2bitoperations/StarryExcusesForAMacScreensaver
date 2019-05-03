//
//  StarryExcuseForAView.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 2019-04-29
//  forked from Marcus Kida's work https://github.com/kimar/DeveloperExcuses
//  port of Evan Green's implementation for Windows https://github.com/evangreen/starryn
//  released under the MIT license
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
    private var bitmapBackedContext: CGContext?
    private var traceEnabled: Bool
    private lazy var configSheetController: StarryConfigSheetController = StarryConfigSheetController(windowNibName: "StarryExcusesConfigSheet")
    private var defaultsManager = StarryDefaultsManager()
    
    public override var hasConfigureSheet: Bool {
        get { return true }
    }
    
    public override var configureSheet: NSWindow? {
        get { return configSheetController.window }
    }
    
    override init?(frame: NSRect, isPreview: Bool) {
        self.traceEnabled = false
        super.init(frame: frame, isPreview: isPreview)
        os_log("start skyline init")
        
        if self.log == nil {
            self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        }

        self.animationTimeInterval = TimeInterval(0.1)
    }
    
    required init?(coder decoder: NSCoder) {
        self.traceEnabled = false
        super.init(coder: decoder)
    }
    
    override func startAnimation() {
        super.startAnimation()
        
    }
    
    override func stopAnimation() {
        super.stopAnimation()
    }
    
    override open func animateOneFrame() {
        guard let context = getCGContext() else {
            os_log("animateOneFrame abort, context couldn't be fetched", log: self.log!, type: .fault)
            return
        }
        
        // do we need to create a new skyline?
        if (skyline?.shouldClearNow() ?? false) {
            initSkyline(xMax: skyline!.width, yMax: skyline!.height)
            clearScreen(contextOpt: context)
        }
 
        // do the rendering with whatever context we were able to grab
        self.skylineRenderer?.drawSingleFrame(context: context)
        
        // if we're using a bitmap, be sure to flush the buffer and request a redraw
        if (bitmapBuffer != nil) {
            context.flush()
            self.needsDisplay = true
        }
    }
    
    private func clearScreen(contextOpt: CGContext?) {
        guard let context = contextOpt else {
            os_log("context not present, can't clear", log: self.log!, type: .fault)
            return
        }
        let size = CGSize(width: context.width, height: context.height)
        let rect = CGRect(origin: CGPoint(x: 0, y: 0), size: size)
        context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        context.fill(rect)
        
        os_log("screen cleared", log: self.log!, type: .info)
    }
    
    private func getContextFromBitmap() -> CGContext? {
        guard let bitmapContext = NSGraphicsContext(bitmapImageRep: self.bitmapBuffer!)?.cgContext else {
            os_log("context couldn't be fetched or created from bitmap!", log: self.log!, type: .fault)
            return nil
        }
        return bitmapContext
    }
    
    private func getCGContext() -> CGContext? {
        // WOW osx graphics devel is tedious... apparently mojave broke getting a context inside animateOneFrame...
        // https://github.com/lionheart/openradar-mirror/issues/20659
        
        // if we can find the current (thread?) cgContext, use it.
        // if we cannot, then use a "fake" context backed by a bitmap.
        let context: CGContext
        
        if (NSGraphicsContext.current != nil) {
            if (traceEnabled) {
                os_log("using real graphics context", log: self.log!, type: .debug)
            }
            context = NSGraphicsContext.current!.cgContext
        } else {
            if (traceEnabled) {
                os_log("using fake graphics context", log: self.log!, type: .debug)
            }
            
            if (bitmapBuffer == nil) {
                bitmapBuffer = self.bitmapImageRepForCachingDisplay(in: self.bounds)
                self.bitmapBackedContext = self.getContextFromBitmap()
                self.clearScreen(contextOpt: self.bitmapBackedContext)
                return self.bitmapBackedContext
            } else {
                return getContextFromBitmap()
            }
        }
        
        return context
    }
    
    fileprivate func initSkyline(xMax: Int, yMax: Int) {
        do {
            self.skyline = try Skyline(screenXMax: xMax,
                                       screenYMax: yMax,
                                       starsPerUpdate: 80,
                                       log: self.log!,
                                       traceEnabled: traceEnabled)
            self.skylineRenderer = SkylineCoreRenderer(skyline: self.skyline!, log: self.log!, traceEnabled: self.traceEnabled)
        } catch {
            let msg = "\(error)"
            os_log("unable to init skyline %{public}@", log: self.log!, type: .fault, msg)
        }
        os_log("created skyline", log: self.log!, type: .info)
    }
    
    override open func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            os_log("skyline draw abort, context couldn't be fetched", log: self.log!, type: .fault)
            return
        }
        
        if (self.skyline == nil) {
            clearScreen(contextOpt: context)
            initSkyline(xMax: Int(rect.width), yMax: Int(rect.height))
        }
        
        if (bitmapBuffer != nil && bitmapBuffer?.cgImage != nil) {
            let cgImage = bitmapBuffer!.cgImage!
            if (traceEnabled) {
                os_log("drawing image", log: self.log!, type: .debug)
            }
            context.draw(cgImage, in: rect)
        }
        
    }
}
