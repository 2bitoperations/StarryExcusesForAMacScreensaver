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
    private lazy var configSheetController: StarryConfigSheetController = StarryConfigSheetController(windowNibName: "StarryExcusesConfigSheet")
    private var currentContext: CGContext?
    private var defaultsManager = StarryDefaultsManager()
    private var image: CGImage?
    private var imageView: NSImageView?
    private var log: OSLog?
    private var size: CGSize?
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var traceEnabled: Bool

    override init?(frame: NSRect, isPreview: Bool) {
        self.traceEnabled = false
        super.init(frame: frame, isPreview: isPreview)
        
        if self.log == nil {
            self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        }
        os_log("start skyline init", log: self.log!)
        
        self.animationTimeInterval = TimeInterval(0.1)
        
        registerListeners()
    }
    
    required init?(coder decoder: NSCoder) {
        self.traceEnabled = false
        super.init(coder: decoder)
    }
    
    deinit {
        deallocateResources()
    }

    public override var configureSheet: NSWindow? {
        get {
            configSheetController.setView(view: self)
            return configSheetController.window
        }
    }

    public override var hasConfigureSheet: Bool {
        get { return true }
    }
    
    override open func animateOneFrame() {
        guard let context = self.currentContext else {
            os_log("context not present, can't animate one", log: self.log!, type: .fault)
            return
        }
        guard let skyline = self.skyline else {
            os_log("skyline not present, can't animate one", log: self.log!, type: .fault)
            return
        }
        guard let size = self.size else {
            os_log("size not present, can't animate one", log: self.log!, type: .fault)
            return
        }
        guard let imageView = self.imageView else {
            os_log("imageView not present, can't animate one", log: self.log!, type: .fault)
            return
        }
        guard let skylineRenderer = self.skylineRenderer else {
            os_log("renderer not present, can't animate one", log: self.log!, type: .fault)
            return
        }
        
        if (skyline.shouldClearNow()) {
            os_log("should clear", log: self.log!)
            self.initSkyline(xMax: Int(context.width), yMax: Int(context.height))
            self.clearScreen(contextOpt: context)
        }
        
        skylineRenderer.drawSingleFrame(context: context)
        
        imageView.image = NSImage(cgImage: context.makeImage()!, size: size)
    }

    override func startAnimation() {
        let image = screenshot()
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height), bitsPerComponent: image.bitsPerComponent, bytesPerRow: image.bytesPerRow, space: image.colorSpace!, bitmapInfo: image.alphaInfo.rawValue)!
        self.size = CGSize.init(width: context.width, height: context.height)
        self.currentContext = context
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(frame.width), height: Int(frame.height)))
        
        if (self.skyline == nil) {
            clearScreen(contextOpt: context)
            initSkyline(xMax: Int(context.width), yMax: Int(context.height))
        }
        
        self.image = context.makeImage()!
        
        self.imageView = NSImageView(frame: NSRect(origin: CGPoint.init(), size: self.size!))
        self.imageView?.image = NSImage(cgImage: image, size: self.size!)
        addSubview(imageView!)
        os_log("leaving startAnimation %d %d", log: self.log!,
               context.width, context.height)
        super.startAnimation()
        
    }

    override func stopAnimation() {
        super.stopAnimation()
    }

    func screenshot() -> CGImage {
        let windows = CGWindowListCopyWindowInfo(CGWindowListOption.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
        let loginwindow = windows.first(where: { (element) -> Bool in
            return element[kCGWindowOwnerName as String] as! String == "loginwindow"
        })
        let loginwindowID = (loginwindow != nil) ? CGWindowID(loginwindow![kCGWindowNumber as String] as! Int) : kCGNullWindowID
        return CGWindowListCreateImage(CGDisplayBounds(self.window?.screen?.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as! CGDirectDisplayID),
                                       CGWindowListOption.optionOnScreenBelowWindow, loginwindowID, CGWindowImageOption.nominalResolution)!
    }

    func settingsChanged() {
        self.skyline = nil
        self.skylineRenderer = nil
    }

    @objc func willStopHandler(_ aNotification: Notification) {
        if (!isPreview) {
            os_log("willStop received, not a preview, exiting.", log: self.log!)
            NSApplication.shared.terminate(nil)
        }
    }

    private func clearScreen(contextOpt: CGContext?) {
        guard let context = contextOpt else {
            os_log("context not present, can't clear", log: self.log!, type: .fault)
            return
        }
        let rect = CGRect(origin: CGPoint(x: 0, y: 0), size: self.size!)
        context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        context.fill(rect)
        
        os_log("screen cleared", log: self.log!)
    }
    
    private func deallocateResources() {
        imageView?.removeFromSuperview()
        imageView = nil
        currentContext?.flush()
        currentContext = nil
        skyline = nil
        skylineRenderer = nil
        
        os_log("deallocated resources", log: self.log!)
    }

    fileprivate func initSkyline(xMax: Int, yMax: Int) {
        do {
            self.skyline = try Skyline(screenXMax: xMax,
                                       screenYMax: yMax,
                                       buildingHeightPercentMax: self.defaultsManager.buildingHeight,
                                       starsPerUpdate: self.defaultsManager.starsPerUpdate,
                                       log: self.log!,
                                       clearAfterDuration: TimeInterval(self.defaultsManager.secsBetweenClears),
                                       traceEnabled: traceEnabled)
            self.skylineRenderer = SkylineCoreRenderer(skyline: self.skyline!, log: self.log!, traceEnabled: self.traceEnabled)
        } catch {
            let msg = "\(error)"
            os_log("unable to init skyline %{public}@", log: self.log!, type: .fault, msg)
        }
        os_log("created skyline", log: self.log!)
    }

    // holy moly this was driving me crazy
    // https://zsmb.co/building-a-macos-screen-saver-in-kotlin/#how-do-we-fix-this
    // thanks, Márton Braun. finding a workaround for this bug is a huge help.
    private func registerListeners() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(self.willStopHandler(_:)),
            name: Notification.Name("com.apple.screensaver.willstop"),
            object: nil
        )
        os_log("willStop listener registered.", log: self.log!)
    }
}
