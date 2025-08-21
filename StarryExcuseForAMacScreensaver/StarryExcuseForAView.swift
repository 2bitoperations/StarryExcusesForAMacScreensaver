
//
//  StarryExcuseForAView.swift
//  StarryExcuseForAMacScreensaver
//

import ScreenSaver
import Foundation
import os
import CoreGraphics
import QuartzCore
import Metal

class StarryExcuseForAView: ScreenSaverView {
    private lazy var configSheetController: StarryConfigSheetController = StarryConfigSheetController(windowNibName: "StarryExcusesConfigSheet")
    private var defaultsManager = StarryDefaultsManager()
    
    // Replaced prior bitmap CALayer approach with a CAMetalLayer + Metal renderer.
    private var metalLayer: CAMetalLayer?
    private var metalRenderer: StarryMetalRenderer?
    
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
        os_log("StarryExcuseForAView internal init (preview=%{public}@)",
               log: log!, type: .info, isPreview ? "true" : "false")
        
        defaultsManager.validateAndCorrectMoonSettings(log: log!)
        animationTimeInterval = 0.1
        registerListeners()
    }
    
    deinit { deallocateResources() }
    
    override var configureSheet: NSWindow? {
        os_log("configureSheet requested", log: log!, type: .info)
        configSheetController.setView(view: self)
        // Force nib load
        _ = configSheetController.window
        
        if let win = configSheetController.window {
            return win
        } else {
            os_log("Nib-based config sheet failed to load, providing fallback sheet window", log: log!, type: .error)
            return createFallbackSheetWindow()
        }
    }
    
    override var hasConfigureSheet: Bool { true }
    
    override func animateOneFrame() {
        guard let engine = engine,
              let metalRenderer = metalRenderer,
              let metalLayer = metalLayer else { return }
        
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        engine.resizeIfNeeded(newSize: bounds.size)
        metalLayer.frame = bounds
        metalRenderer.updateDrawableSize(size: bounds.size, scale: backingScale)
        
        let frameUpdate = engine.advanceFrameForMetal()
        metalRenderer.render(frame: frameUpdate)
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
            if self.metalLayer == nil {
                self.wantsLayer = true
                let mLayer = CAMetalLayer()
                mLayer.frame = self.bounds
                self.layer?.addSublayer(mLayer)
                self.metalLayer = mLayer
                if let log = self.log {
                    self.metalRenderer = StarryMetalRenderer(layer: mLayer, log: log)
                }
            } else {
                metalLayer?.frame = bounds
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
            buildingFrequency: defaultsManager.buildingFrequency,
            secsBetweenClears: defaultsManager.secsBetweenClears,
            moonTraversalMinutes: defaultsManager.moonTraversalMinutes,
            moonDiameterScreenWidthPercent: defaultsManager.moonDiameterScreenWidthPercent,
            moonBrightBrightness: defaultsManager.moonBrightBrightness,
            moonDarkBrightness: defaultsManager.moonDarkBrightness,
            moonPhaseOverrideEnabled: defaultsManager.moonPhaseOverrideEnabled,
            moonPhaseOverrideValue: defaultsManager.moonPhaseOverrideValue,
            traceEnabled: traceEnabled,
            showLightAreaTextureFillMask: defaultsManager.showLightAreaTextureFillMask,
            shootingStarsEnabled: defaultsManager.shootingStarsEnabled,
            shootingStarsAvgSeconds: defaultsManager.shootingStarsAvgSeconds,
            shootingStarsDirectionMode: defaultsManager.shootingStarsDirectionMode,
            shootingStarsLength: defaultsManager.shootingStarsLength,
            shootingStarsSpeed: defaultsManager.shootingStarsSpeed,
            shootingStarsThickness: defaultsManager.shootingStarsThickness,
            shootingStarsBrightness: defaultsManager.shootingStarsBrightness,
            shootingStarsTrailDecay: defaultsManager.shootingStarsTrailDecay,
            shootingStarsDebugShowSpawnBounds: defaultsManager.shootingStarsDebugShowSpawnBounds,
            satellitesEnabled: defaultsManager.satellitesEnabled,
            satellitesAvgSpawnSeconds: defaultsManager.satellitesAvgSpawnSeconds,
            satellitesSpeed: defaultsManager.satellitesSpeed,
            satellitesSize: defaultsManager.satellitesSize,
            satellitesBrightness: defaultsManager.satellitesBrightness,
            satellitesTrailing: defaultsManager.satellitesTrailing,
            satellitesTrailDecay: defaultsManager.satellitesTrailDecay,
            debugOverlayEnabled: defaultsManager.debugOverlayEnabled
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
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
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
    
    // Fallback plain sheet if nib fails (ensures Options button still appears)
    private func createFallbackSheetWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = "Starry Excuses (Fallback Config)"
        let label = NSTextField(labelWithString: "Configuration sheet failed to load.\nPlease reinstall or report an issue.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 60, width: 360, height: 120)
        win.contentView?.addSubview(label)
        let button = NSButton(title: "Close", target: self, action: #selector(closeFallbackSheet))
        button.frame = NSRect(x: 160, y: 20, width: 80, height: 30)
        win.contentView?.addSubview(button)
        return win
    }
    
    @objc private func closeFallbackSheet() {
        if let sheetParent = self.window {
            sheetParent.endSheet(sheetParent.attachedSheet ?? NSWindow())
        }
    }
}
