
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
    // Updated: use programmatic config sheet controller (no XIB)
    private lazy var configSheetController: StarryConfigSheetController = {
        let controller = StarryConfigSheetController()
        return controller
    }()
    
    private var defaultsManager = StarryDefaultsManager()
    
    // Replaced prior bitmap CALayer approach with a CAMetalLayer + Metal renderer.
    private var metalLayer: CAMetalLayer?
    private var metalRenderer: StarryMetalRenderer?
    
    private var log: OSLog?
    private var engine: StarryEngine?
    private var traceEnabled: Bool
    private var frameIndex: UInt64 = 0
    private var stoppedRunning: Bool = false   // Tracks whether stopAnimation has been invoked
    
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
        os_log("StarryExcuseForAView internal init (preview=%{public}@) bounds=%{public}@",
               log: log!, type: .info, isPreview ? "true" : "false", NSStringFromRect(bounds))
        
        defaultsManager.validateAndCorrectMoonSettings(log: log!)
        // Set target ~60 FPS
        animationTimeInterval = 1.0 / 60.0
        os_log("Animation interval set to %{public}.4f s (~%{public}.1f FPS)", log: log!, type: .info, animationTimeInterval, 1.0 / animationTimeInterval)
        registerListeners()
    }
    
    deinit { deallocateResources() }
    
    override var configureSheet: NSWindow? {
        os_log("configureSheet requested", log: log!, type: .info)
        
        // Ensure controller knows about this view (idempotent)
        configSheetController.setView(view: self)
        
        // Force window creation (windowDidLoad will build UI programmatically)
        _ = configSheetController.window
        
        if let win = configSheetController.window {
            os_log("Programmatic config sheet window ready", log: log!, type: .info)
            return win
        } else {
            os_log("Programmatic config sheet failed to create window; using fallback sheet window", log: log!, type: .fault)
            return createFallbackSheetWindow()
        }
    }
    
    override var hasConfigureSheet: Bool { true }
    
    override func animateOneFrame() {
        // If stopAnimation has already been called, log and no-op.
        if stoppedRunning {
            os_log("animateOneFrame invoked after stopAnimation; ignoring frame (index would have been #%{public}llu)", log: log ?? .default, type: .error, frameIndex)
            return
        }
        
        frameIndex &+= 1
        let verbose = (frameIndex <= 5) || (frameIndex % 60 == 0)
        if verbose {
            os_log("animateOneFrame #%{public}llu begin", log: log!, type: .info, frameIndex)
        }
        autoreleasepool {
            let size = bounds.size
            if !(size.width >= 1 && size.height >= 1) {
                os_log("animateOneFrame: invalid bounds size %{public}.1fx%{public}.1f — skipping", log: log!, type: .error, Double(size.width), Double(size.height))
                return
            }
            guard let engine = engine else {
                os_log("animateOneFrame: engine is nil — skipping frame", log: log!, type: .error)
                return
            }
            guard let metalRenderer = metalRenderer else {
                os_log("animateOneFrame: metalRenderer is nil — skipping frame", log: log!, type: .error)
                return
            }
            guard let metalLayer = metalLayer else {
                os_log("animateOneFrame: metalLayer is nil — skipping frame", log: log!, type: .error)
                return
            }
            
            // Prefer the view's screen scale (handles multi-display correctly)
            let backingScale = window?.screen?.backingScaleFactor
                ?? window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            let wPx = Int(round(size.width * backingScale))
            let hPx = Int(round(size.height * backingScale))
            if verbose {
                os_log("animateOneFrame: bounds=%{public}.1fx%{public}.1f scale=%{public}.2f drawable target=%{public}dx%{public}d", log: log!, type: .info,
                       Double(size.width), Double(size.height), Double(backingScale), wPx, hPx)
            }
            guard wPx > 0, hPx > 0 else {
                os_log("animateOneFrame: invalid drawable size w=%{public}d h=%{public}d — skipping", log: log!, type: .error, wPx, hPx)
                return
            }
            
            engine.resizeIfNeeded(newSize: size)
            metalLayer.frame = bounds
            metalRenderer.updateDrawableSize(size: size, scale: backingScale)
            
            let t0 = CACurrentMediaTime()
            let drawData = engine.advanceFrameGPU()
            if verbose {
                os_log("animateOneFrame: drawData base=%{public}d sat=%{public}d shoot=%{public}d moon=%{public}@ clearAll=%{public}@",
                       log: log!, type: .info,
                       drawData.baseSprites.count, drawData.satellitesSprites.count, drawData.shootingSprites.count,
                       drawData.moon != nil ? "yes" : "no",
                       drawData.clearAll ? "yes" : "no")
            }
            metalRenderer.render(drawData: drawData)
            let t1 = CACurrentMediaTime()
            if verbose {
                os_log("animateOneFrame #%{public}llu end (%.2f ms)", log: log!, type: .info, frameIndex, (t1 - t0) * 1000.0)
            }
        }
    }
    
    override func startAnimation() {
        super.startAnimation()
        stoppedRunning = false
        os_log("startAnimation called", log: log!, type: .info)
        Task { await setupAnimation() }
    }
    
    override func stopAnimation() {
        os_log("stopAnimation called", log: log!, type: .info)
        stoppedRunning = true
        super.stopAnimation()
    }
    
    private func setupAnimation() async {
        os_log("starting setupAnimation", log: log!)
        if engine == nil {
            engine = StarryEngine(size: bounds.size,
                                  log: log!,
                                  config: currentRuntimeConfig())
            os_log("Engine created (size=%{public}.0fx%{public}.0f)", log: log!, type: .info, Double(bounds.width), Double(bounds.height))
        }
        await MainActor.run {
            if self.metalLayer == nil {
                self.wantsLayer = true
                let mLayer = CAMetalLayer()
                mLayer.frame = self.bounds
                // Initialize contentsScale immediately for crisp output and correct drawable sizing
                let scale = self.window?.screen?.backingScaleFactor
                    ?? self.window?.backingScaleFactor
                    ?? NSScreen.main?.backingScaleFactor
                    ?? 2.0
                mLayer.contentsScale = scale
                self.layer?.addSublayer(mLayer)
                self.metalLayer = mLayer
                os_log("CAMetalLayer created and added. contentsScale=%{public}.2f", log: self.log!, type: .info, Double(scale))
                if let log = self.log {
                    self.metalRenderer = StarryMetalRenderer(layer: mLayer, log: log)
                    if self.metalRenderer == nil {
                        os_log("Failed to create StarryMetalRenderer", log: self.log!, type: .fault)
                    } else {
                        os_log("StarryMetalRenderer created", log: self.log!, type: .info)
                    }
                    // Ensure drawable is sized before first frame if valid
                    let size = self.bounds.size
                    let wPx = Int(round(size.width * scale))
                    let hPx = Int(round(size.height * scale))
                    if wPx > 0, hPx > 0 {
                        self.metalRenderer?.updateDrawableSize(size: size, scale: scale)
                        os_log("Initial drawableSize update applied (%{public}dx%{public}d)", log: self.log!, type: .info, wPx, hPx)
                    } else {
                        os_log("Initial drawableSize update skipped due to invalid size (%{public}dx%{public}d)", log: self.log!, type: .error, wPx, hPx)
                    }
                    // Propagate trail half-lives into renderer from defaults
                    self.metalRenderer?.setTrailHalfLives(
                        satellites: self.defaultsManager.satellitesTrailHalfLifeSeconds,
                        shooting: self.defaultsManager.shootingStarsTrailHalfLifeSeconds
                    )
                }
            } else {
                os_log("setupAnimation: reusing existing CAMetalLayer", log: self.log!, type: .info)
                metalLayer?.frame = bounds
            }
        }
        os_log("leaving setupAnimation %d %d",
               log: log!,
               Int(bounds.width), Int(bounds.height))
    }
    
    private func currentRuntimeConfig() -> StarryRuntimeConfig {
        return StarryRuntimeConfig(
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
            shootingStarsDebugShowSpawnBounds: defaultsManager.shootingStarsDebugShowSpawnBounds,
            satellitesEnabled: defaultsManager.satellitesEnabled,
            satellitesAvgSpawnSeconds: defaultsManager.satellitesAvgSpawnSeconds,
            satellitesSpeed: defaultsManager.satellitesSpeed,
            satellitesSize: defaultsManager.satellitesSize,
            satellitesBrightness: defaultsManager.satellitesBrightness,
            satellitesTrailing: defaultsManager.satellitesTrailing,
            debugOverlayEnabled: defaultsManager.debugOverlayEnabled,
            debugDropBaseEveryNFrames: 0,
            debugForceClearEveryNFrames: 0,
            debugLogEveryFrame: false,
            buildingLightsPerUpdate: defaultsManager.buildingLightsPerUpdate,
            disableFlasherOnBase: false,
            // New per-second rates (0 => derive from legacy per-update * 10 FPS)
            starsPerSecond: 0,
            buildingLightsPerSecond: 0
        )
    }
    
    func settingsChanged() {
        os_log("settingsChanged: applying updated defaults to engine", log: log!, type: .info)
        if let engine = engine {
            engine.updateConfig(currentRuntimeConfig())
        } else {
            // If engine doesn't exist yet, create it.
            self.engine = StarryEngine(size: bounds.size,
                                       log: log!,
                                       config: currentRuntimeConfig())
        }
        // Update renderer half-lives immediately
        metalRenderer?.setTrailHalfLives(
            satellites: defaultsManager.satellitesTrailHalfLifeSeconds,
            shooting: defaultsManager.shootingStarsTrailHalfLifeSeconds
        )
    }
    
    @objc func willStopHandler(_ note: Notification) {
        if !isPreview {
            os_log("willStop received, exiting.", log: log!)
            NSApplication.shared.terminate(nil)
        } else {
            os_log("willStop received (preview mode), ignoring terminate", log: log!, type: .info)
        }
    }
    
    private func deallocateResources() {
        os_log("Deallocating resources: tearing down renderer, layer, engine", log: log!, type: .info)
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        engine = nil
    }
    
    private func registerListeners() {
        os_log("Registering willStop listener", log: log!, type: .info)
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(self.willStopHandler(_:)),
            name: Notification.Name("com.apple.screensaver.willstop"),
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(self.willStopHandler(_:)),
            name: Notification.Name("com.apple.screensaver.didstop"),
            object: nil
        )
    }
    
    // Fallback plain sheet if programmatic controller somehow fails (should be rare)
    private func createFallbackSheetWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = "Starry Excuses (Fallback Config)"
        let label = NSTextField(labelWithString: "Configuration sheet failed to initialize.\nPlease reinstall or report an issue.")
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
