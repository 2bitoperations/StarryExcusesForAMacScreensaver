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
    private var defaultsManager = StarryDefaultsManager()
    private var imageView: NSImageView?
    private var log: OSLog?
    private var engine: StarryEngine?
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
        guard let engine = engine,
              let imageView = imageView else {
            return
        }
        engine.resizeIfNeeded(newSize: bounds.size)
        if let cg = engine.advanceFrame() {
            imageView.image = NSImage(cgImage: cg, size: bounds.size)
        }
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
        if engine == nil {
            engine = StarryEngine(size: bounds.size,
                                  log: log!,
                                  config: currentRuntimeConfig())
        }
        await MainActor.run {
            if imageView == nil {
                let iv = NSImageView(frame: bounds)
                iv.imageScaling = .scaleProportionallyUpOrDown
                addSubview(iv)
                imageView = iv
            } else {
                imageView?.frame = bounds
            }
        }
        os_log("leaving setupAnimation %d %d",
               log: log!,
               Int(bounds.width), Int(bounds.height))
    }
    
    private func currentRuntimeConfig() -> StarryRuntimeConfig {
        StarryRuntimeConfig(
            starsPerUpdate: defaultsManager.starsPerUpdate,
            buildingHeight: defaultsManager.buildingHeight,
            secsBetweenClears: defaultsManager.secsBetweenClears,
            moonTraversalMinutes: defaultsManager.moonTraversalMinutes,
            moonMinRadius: defaultsManager.moonMinRadius,
            moonMaxRadius: defaultsManager.moonMaxRadius,
            moonBrightBrightness: defaultsManager.moonBrightBrightness,
            moonDarkBrightness: defaultsManager.moonDarkBrightness,
            traceEnabled: traceEnabled
        )
    }
    
    func settingsChanged() {
        // Rebuild the engine with the persisted defaults after user saves changes.
        engine = StarryEngine(size: bounds.size,
                              log: log!,
                              config: currentRuntimeConfig())
    }
    
    @objc func willStopHandler(_ note: Notification) {
        if !isPreview {
            os_log("willStop received, exiting.", log: log!)
            NSApplication.shared.terminate(nil)
        }
    }
    
    private func deallocateResources() {
        imageView?.removeFromSuperview()
        imageView = nil
        engine = nil
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
