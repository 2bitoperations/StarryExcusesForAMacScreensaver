//
//  StarryExcuseForAView.swift
//  StarryExcuseForAMacScreensaver
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
        
        self.requiredInternalInit()
    }
    
    required init?(coder decoder: NSCoder) {
        self.traceEnabled = false
        super.init(coder: decoder)
        
        self.requiredInternalInit()
    }
    
    private func requiredInternalInit() {
        if log == nil {
            log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        }
        os_log("internal init", log: log!)
        
        defaultsManager.validateAndCorrectMoonSettings(log: log!)
        animationTimeInterval = 0.1
        registerListeners()
    }
    
    deinit { deallocateResources() }
    
    override var configureSheet: NSWindow? {
        configSheetController.setView(view: self)
        return configSheetController.window
    }
    
    override var hasConfigureSheet: Bool { true }
    
    override func animateOneFrame() {
        guard let context = currentContext,
              let skyline = skyline,
              let size = size,
              let imageView = imageView,
              let skylineRenderer = skylineRenderer else {
            return
        }
        if skyline.shouldClearNow() {
            initSkyline(xMax: Int(context.width), yMax: Int(context.height))
            clearScreen(contextOpt: context)
        }
        skylineRenderer.drawSingleFrame(context: context)
        imageView.image = NSImage(cgImage: context.makeImage()!, size: size)
    }
    
    override func startAnimation() {
        super.startAnimation()
        Task { await setupAnimation() }
    }
    
    override func stopAnimation() {
        super.stopAnimation()
    }
    
    private func setupAnimation() async {
        os_log("starting setupAnimation", log: log!)
        let ctx = CGContext(data: nil,
                            width: Int(frame.width),
                            height: Int(frame.height),
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        size = CGSize(width: ctx.width, height: ctx.height)
        currentContext = ctx
        ctx.interpolationQuality = .high
        if skyline == nil {
            clearScreen(contextOpt: ctx)
            initSkyline(xMax: ctx.width, yMax: ctx.height)
        }
        image = ctx.makeImage()
        await MainActor.run {
            imageView = NSImageView(frame: NSRect(origin: .zero, size: size!))
            imageView?.image = NSImage(cgImage: image!, size: size!)
            addSubview(imageView!)
        }
        os_log("leaving setupAnimation %d %d", log: log!, ctx.width, ctx.height)
    }
    
    func settingsChanged() {
        skyline = nil
        skylineRenderer = nil
    }
    
    @objc func willStopHandler(_ note: Notification) {
        if !isPreview {
            os_log("willStop received, exiting.", log: log!)
            NSApplication.shared.terminate(nil)
        }
    }
    
    private func clearScreen(contextOpt: CGContext?) {
        guard let ctx = contextOpt, let size = size else { return }
        ctx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        ctx.fill(CGRect(origin: .zero, size: size))
    }
    
    private func deallocateResources() {
        imageView?.removeFromSuperview()
        imageView = nil
        currentContext?.flush()
        currentContext = nil
        skyline = nil
        skylineRenderer = nil
    }
    
    fileprivate func initSkyline(xMax: Int, yMax: Int) {
        // Validate potentially corrupted or logically invalid persisted values before use.
        if let log = log {
            defaultsManager.validateAndCorrectMoonSettings(log: log)
        }
        do {
            let traversalMinutes = defaultsManager.moonTraversalMinutes
            let minRadius = defaultsManager.moonMinRadius
            let maxRadius = defaultsManager.moonMaxRadius
            let bright = defaultsManager.moonBrightBrightness
            let dark = defaultsManager.moonDarkBrightness
            skyline = try Skyline(screenXMax: xMax,
                                  screenYMax: yMax,
                                  buildingHeightPercentMax: defaultsManager.buildingHeight,
                                  starsPerUpdate: defaultsManager.starsPerUpdate,
                                  log: log!,
                                  clearAfterDuration: TimeInterval(defaultsManager.secsBetweenClears),
                                  traceEnabled: traceEnabled,
                                  moonTraversalSeconds: Double(traversalMinutes) * 60.0,
                                  moonMinRadius: minRadius,
                                  moonMaxRadius: maxRadius,
                                  moonBrightBrightness: bright,
                                  moonDarkBrightness: dark)
            skylineRenderer = SkylineCoreRenderer(skyline: skyline!, log: log!, traceEnabled: traceEnabled)
        } catch {
            os_log("unable to init skyline %{public}@", log: log!, type: .fault, "\(error)")
        }
    }
    
    private func registerListeners() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(self.willStopHandler(_:)),
            name: Notification.Name("com.apple.screensaver.willstop"),
            object: nil
        )
    }
}
