//
//  StarryExcuseForAView.swift
//  StarryExcuseForAMacScreensaver
//

import CoreGraphics
import Foundation
import Metal
import QuartzCore
import ScreenSaver
import os

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
    private var stoppedRunning: Bool = false  // Tracks whether stopAnimation has been invoked (legacy path)

    // Inferred visibility / availability state
    private var rendererDrawableAvailable: Bool = true
    private var lastVisibilityState: Bool = true
    private var invisibleConsecutiveFrames: UInt64 = 0
    private var invisibilityBeganTime: CFTimeInterval?
    private var resourcesReleasedWhileInvisible: Bool = false
    private let visibilityReleaseResourcesThresholdSeconds: Double = 3.0  // partial (graphics) release
    private var pendingVisibilityReinit: Bool = false

    // Long term invisibility management
    private let invisibilityFullReleaseThresholdSeconds: Double = 20.0  // full release + log suppression threshold
    private var fullyReleasedAfterLongInvisibility: Bool = false
    private var lastLoggedVisibilityState: Bool?
    private var lastLoggedVisibilityReason: String?

    // New heuristic support
    private var firstAnimationWallTime: CFTimeInterval?
    private let initialVisibilityGraceSeconds: Double = 1.5  // optimistic visibility during startup flicker
    private var lastCGWindowCheckFrame: UInt64 = 0
    private var cachedCGWindowOnscreen: Bool = true
    private let cgWindowRecheckIntervalFrames: UInt64 = 30  // ~0.5s at 60 FPS
    private var lastVisibilityReason: String = "initial"
    private var lastVisibilityDecisionPath: String = "initial"

    // Periodic visibility diagnostics (every 2 seconds)
    private let visibilityCheckIntervalSeconds: CFTimeInterval = 2.0
    private var lastVisibilityCheckWallTime: CFTimeInterval = 0
    // (We removed the per-frame visibility check; now we only evaluate every 2 seconds or on explicit triggers.)

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
            log = OSLog(
                subsystem: "com.2bitoperations.screensavers.starry",
                category: "Skyline"
            )
        }
        os_log(
            "StarryExcuseForAView internal init (preview=%{public}@) bounds=%{public}@",
            log: log!,
            type: .info,
            isPreview ? "true" : "false",
            NSStringFromRect(bounds)
        )

        defaultsManager.validateAndCorrectMoonSettings(log: log!)
        animationTimeInterval = 1.0 / 60.0
        os_log(
            "Animation interval set to %{public}.4f s (~%{public}.1f FPS)",
            log: log!,
            type: .info,
            animationTimeInterval,
            1.0 / animationTimeInterval
        )
        registerListeners()
    }

    deinit { deallocateResources() }

    override var configureSheet: NSWindow? {
        os_log("configureSheet requested", log: log!, type: .info)
        configSheetController.setView(view: self)
        _ = configSheetController.window
        if let win = configSheetController.window {
            os_log(
                "Programmatic config sheet window ready",
                log: log!,
                type: .info
            )
            return win
        } else {
            os_log(
                "Programmatic config sheet failed to create window; using fallback sheet window",
                log: log!,
                type: .fault
            )
            return createFallbackSheetWindow()
        }
    }

    override var hasConfigureSheet: Bool { true }

    override func animateOneFrame() {
        if stoppedRunning {
            if defaultsManager.debugOverlayEnabled {
                os_log(
                    "animateOneFrame[#%{public}llu] skipped (already stopped)",
                    log: log ?? .default,
                    type: .info,
                    frameIndex
                )
            }
            return
        }

        if firstAnimationWallTime == nil {
            firstAnimationWallTime = CACurrentMediaTime()
        }

        frameIndex &+= 1

        // Perform visibility check every visibilityCheckIntervalSeconds
        let now = CACurrentMediaTime()
        if now - lastVisibilityCheckWallTime >= visibilityCheckIntervalSeconds {
            lastVisibilityCheckWallTime = now
            // Force evaluation & always request decision (internal suppression may skip logging)
            inferVisibilityState(
                frameIndex: frameIndex,
                force: true,
                logEveryCheck: true
            )
        }

        // New rule: if not currently visible (and thus not transitioning to visible in this frame),
        // do NOT advance the engine or render.
        if !shouldRenderCurrentFrame() {
            if defaultsManager.debugOverlayEnabled
                && (frameIndex <= 5 || frameIndex % 120 == 0)
            {
                os_log(
                    "animateOneFrame[#%{public}llu] skipped (visible=%{public}@ drawable=%{public}@ released=%{public}@ reason=%{public}@ path=%{public}@)",
                    log: log!,
                    type: .info,
                    frameIndex,
                    lastVisibilityState ? "yes" : "no",
                    rendererDrawableAvailable ? "yes" : "no",
                    resourcesReleasedWhileInvisible ? "yes" : "no",
                    lastVisibilityReason,
                    lastVisibilityDecisionPath
                )
            }
            return
        }

        if pendingVisibilityReinit {
            pendingVisibilityReinit = false
            if resourcesReleasedWhileInvisible {
                os_log(
                    "Visibility restored: recreating resources before frame #%{public}llu",
                    log: log!,
                    type: .info,
                    frameIndex
                )
                recreateResourcesIfNeeded()
            }
        }

        let loggingEnabled = defaultsManager.debugOverlayEnabled
        let cadenceLog =
            loggingEnabled && (frameIndex <= 5 || frameIndex % 60 == 0)
        if cadenceLog {
            os_log(
                "animateOneFrame[#%{public}llu] begin",
                log: log!,
                type: .info,
                frameIndex
            )
        }

        autoreleasepool {
            let size = bounds.size
            if !(size.width >= 1 && size.height >= 1) {
                if loggingEnabled {
                    os_log(
                        "animateOneFrame[#%{public}llu] invalid bounds size %.1f x %.1f — skipped",
                        log: log!,
                        type: .error,
                        frameIndex,
                        Double(size.width),
                        Double(size.height)
                    )
                }
                return
            }
            guard let engine = engine else {
                if loggingEnabled {
                    os_log(
                        "animateOneFrame[#%{public}llu] engine nil — skipped",
                        log: log!,
                        type: .error,
                        frameIndex
                    )
                }
                return
            }
            guard let metalRenderer = metalRenderer else {
                if loggingEnabled {
                    os_log(
                        "animateOneFrame[#%{public}llu] metalRenderer nil — skipped",
                        log: log!,
                        type: .error,
                        frameIndex
                    )
                }
                return
            }
            guard let metalLayer = metalLayer else {
                if loggingEnabled {
                    os_log(
                        "animateOneFrame[#%{public}llu] metalLayer nil — skipped",
                        log: log!,
                        type: .error,
                        frameIndex
                    )
                }
                return
            }

            let backingScale =
                window?.screen?.backingScaleFactor
                ?? window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            let wPx = Int(round(size.width * backingScale))
            let hPx = Int(round(size.height * backingScale))
            if cadenceLog {
                os_log(
                    "animateOneFrame[#%{public}llu] bounds=%.1fx%.1f scale=%.2f drawableTarget=%dx%d",
                    log: log!,
                    type: .info,
                    frameIndex,
                    Double(size.width),
                    Double(size.height),
                    Double(backingScale),
                    wPx,
                    hPx
                )
            }
            guard wPx > 0, hPx > 0 else {
                if loggingEnabled {
                    os_log(
                        "animateOneFrame[#%{public}llu] invalid drawable size w=%d h=%d — skipped",
                        log: log!,
                        type: .error,
                        frameIndex,
                        wPx,
                        hPx
                    )
                }
                return
            }

            engine.resizeIfNeeded(newSize: size)
            metalLayer.frame = bounds
            metalRenderer.updateDrawableSize(size: size, scale: backingScale)

            let t0 = CACurrentMediaTime()
            let drawData = engine.advanceFrameGPU()
            if cadenceLog {
                os_log(
                    "animateOneFrame[#%{public}llu] sprites base=%d sat=%d shooting=%d moon=%{public}@ clearAll=%{public}@",
                    log: log!,
                    type: .info,
                    frameIndex,
                    drawData.baseSprites.count,
                    drawData.satellitesSprites.count,
                    drawData.shootingSprites.count,
                    drawData.moon != nil ? "yes" : "no",
                    drawData.clearAll ? "yes" : "no"
                )
            }
            metalRenderer.render(drawData: drawData)
            if cadenceLog {
                let t1 = CACurrentMediaTime()
                os_log(
                    "animateOneFrame[#%{public}llu] end (%.2f ms)",
                    log: log!,
                    type: .info,
                    frameIndex,
                    (t1 - t0) * 1000.0
                )
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
            engine = StarryEngine(
                size: bounds.size,
                log: log!,
                config: currentRuntimeConfig()
            )
            os_log(
                "Engine created (size=%.0fx%.0f)",
                log: log!,
                type: .info,
                Double(bounds.width),
                Double(bounds.height)
            )
        }
        await MainActor.run {
            if self.metalLayer == nil {
                self.wantsLayer = true
                let mLayer = CAMetalLayer()
                mLayer.frame = self.bounds
                let scale =
                    self.window?.screen?.backingScaleFactor
                    ?? self.window?.backingScaleFactor
                    ?? NSScreen.main?.backingScaleFactor
                    ?? 2.0
                mLayer.contentsScale = scale
                self.layer?.addSublayer(mLayer)
                self.metalLayer = mLayer
                os_log(
                    "CAMetalLayer created and added. contentsScale=%.2f",
                    log: self.log!,
                    type: .info,
                    Double(scale)
                )
                if let log = self.log {
                    self.metalRenderer = StarryMetalRenderer(
                        layer: mLayer,
                        log: log
                    )
                    if self.metalRenderer == nil {
                        os_log(
                            "Failed to create StarryMetalRenderer",
                            log: self.log!,
                            type: .fault
                        )
                    } else {
                        os_log(
                            "StarryMetalRenderer created",
                            log: self.log!,
                            type: .info
                        )
                    }
                    let size = self.bounds.size
                    let wPx = Int(round(size.width * scale))
                    let hPx = Int(round(size.height * scale))
                    if wPx > 0, hPx > 0 {
                        self.metalRenderer?.updateDrawableSize(
                            size: size,
                            scale: scale
                        )
                        os_log(
                            "Initial drawableSize update applied (%dx%d)",
                            log: self.log!,
                            type: .info,
                            wPx,
                            hPx
                        )
                    } else {
                        os_log(
                            "Initial drawableSize update skipped invalid (%dx%d)",
                            log: self.log!,
                            type: .error,
                            wPx,
                            hPx
                        )
                    }
                    self.metalRenderer?.setTrailHalfLives(
                        satellites: self.defaultsManager
                            .satellitesTrailHalfLifeSeconds,
                        shooting: self.defaultsManager
                            .shootingStarsTrailHalfLifeSeconds
                    )
                }
                if let win = self.window {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(self.windowOcclusionChanged(_:)),
                        name: NSWindow.didChangeOcclusionStateNotification,
                        object: win
                    )
                }
            } else {
                os_log(
                    "setupAnimation: reusing existing CAMetalLayer",
                    log: self.log!,
                    type: .info
                )
                metalLayer?.frame = bounds
            }
        }
        os_log(
            "leaving setupAnimation %.0f %.0f",
            log: log!,
            Double(bounds.width),
            Double(bounds.height)
        )
    }

    private func currentRuntimeConfig() -> StarryRuntimeConfig {
        return StarryRuntimeConfig(
            buildingHeight: defaultsManager.buildingHeight,
            buildingFrequency: defaultsManager.buildingFrequency,
            secsBetweenClears: defaultsManager.secsBetweenClears,
            moonTraversalMinutes: defaultsManager.moonTraversalMinutes,
            moonDiameterScreenWidthPercent: defaultsManager
                .moonDiameterScreenWidthPercent,
            moonBrightBrightness: defaultsManager.moonBrightBrightness,
            moonDarkBrightness: defaultsManager.moonDarkBrightness,
            moonPhaseOverrideEnabled: defaultsManager.moonPhaseOverrideEnabled,
            moonPhaseOverrideValue: defaultsManager.moonPhaseOverrideValue,
            traceEnabled: traceEnabled,
            showLightAreaTextureFillMask: defaultsManager
                .showLightAreaTextureFillMask,
            shootingStarsEnabled: defaultsManager.shootingStarsEnabled,
            shootingStarsAvgSeconds: defaultsManager.shootingStarsAvgSeconds,
            shootingStarsDirectionMode: defaultsManager
                .shootingStarsDirectionMode,
            shootingStarsLength: defaultsManager.shootingStarsLength,
            shootingStarsSpeed: defaultsManager.shootingStarsSpeed,
            shootingStarsThickness: defaultsManager.shootingStarsThickness,
            shootingStarsBrightness: defaultsManager.shootingStarsBrightness,
            shootingStarsDebugShowSpawnBounds: defaultsManager
                .shootingStarsDebugShowSpawnBounds,
            satellitesEnabled: defaultsManager.satellitesEnabled,
            satellitesAvgSpawnSeconds: defaultsManager
                .satellitesAvgSpawnSeconds,
            satellitesSpeed: defaultsManager.satellitesSpeed,
            satellitesSize: defaultsManager.satellitesSize,
            satellitesBrightness: defaultsManager.satellitesBrightness,
            satellitesTrailing: defaultsManager.satellitesTrailing,
            debugOverlayEnabled: defaultsManager.debugOverlayEnabled,
            debugDropBaseEveryNFrames: 0,
            debugForceClearEveryNFrames: 0,
            debugLogEveryFrame: false,
            buildingLightsSpawnPerSecFractionOfMax: defaultsManager
                .buildingLightsSpawnFractionOfMax,
            disableFlasherOnBase: false,
            starSpawnPerSecFractionOfMax: defaultsManager.starSpawnFractionOfMax
        )
    }

    func settingsChanged() {
        os_log(
            "settingsChanged: applying updated defaults to engine",
            log: log!,
            type: .info
        )
        if let engine = engine {
            engine.updateConfig(currentRuntimeConfig())
        } else {
            self.engine = StarryEngine(
                size: bounds.size,
                log: log!,
                config: currentRuntimeConfig()
            )
        }
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
            os_log(
                "willStop received (preview mode), ignoring terminate",
                log: log!,
                type: .info
            )
        }
    }

    @objc func anyScreensaverNotification(_ note: Notification) {
        let name = note.name.rawValue
        guard name.hasPrefix("com.apple.screensaver.") else { return }
        os_log(
            "Received screensaver notification %{public}@ (object=%{public}@ userInfoKeys=%{public}@)",
            log: log ?? .default,
            type: .info,
            name,
            String(describing: note.object),
            note.userInfo?.keys.map { "\($0)" }.joined(separator: ",") ?? "none"
        )
    }

    private func deallocateResources() {
        os_log(
            "Deallocating resources: tearing down renderer, layer, engine",
            log: log!,
            type: .info
        )
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        engine = nil
    }

    private func deallocateResourcesPartial(reason: String) {
        guard !resourcesReleasedWhileInvisible else { return }
        os_log(
            "Partial resource release (invisible) reason=%{public}@ (engine kept)",
            log: log!,
            type: .info,
            reason
        )
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        resourcesReleasedWhileInvisible = true
    }

    private func recreateResourcesIfNeeded() {
        guard resourcesReleasedWhileInvisible else { return }
        resourcesReleasedWhileInvisible = false
        Task { await setupAnimation() }
    }

    private func registerListeners() {
        os_log(
            "Registering distributed screensaver listeners",
            log: log!,
            type: .info
        )

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

    private func createFallbackSheetWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Starry Excuses (Fallback Config)"
        let label = NSTextField(
            labelWithString:
                "Configuration sheet failed to initialize.\nPlease reinstall or report an issue."
        )
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 60, width: 360, height: 120)
        win.contentView?.addSubview(label)
        let button = NSButton(
            title: "Close",
            target: self,
            action: #selector(closeFallbackSheet)
        )
        button.frame = NSRect(x: 160, y: 20, width: 80, height: 30)
        win.contentView?.addSubview(button)
        return win
    }

    @objc private func closeFallbackSheet() {
        if let sheetParent = self.window {
            sheetParent.endSheet(sheetParent.attachedSheet ?? NSWindow())
        }
    }

    // MARK: - Visibility Inference Logic

    @objc private func rendererDrawableAvailabilityChanged(_ note: Notification)
    {
        if let available = note.userInfo?["available"] as? Bool {
            rendererDrawableAvailable = available
            if defaultsManager.debugOverlayEnabled {
                os_log(
                    "Drawable availability changed -> %{public}@",
                    log: log ?? .default,
                    type: .info,
                    available ? "AVAILABLE" : "UNAVAILABLE"
                )
            }
            if available {
                pendingVisibilityReinit = true
            }
        }
    }

    @objc private func windowOcclusionChanged(_ note: Notification) {
        // Force immediate re-evaluation & log it
        inferVisibilityState(
            frameIndex: frameIndex,
            force: true,
            logEveryCheck: true
        )
    }

    private func inferVisibilityState(
        frameIndex: UInt64,
        force: Bool = false,
        logEveryCheck: Bool = false
    ) {
        // Always evaluate when forced (periodic invocation) or when called from explicit triggers.

        let prevVisible = lastVisibilityState
        let prevReason = lastVisibilityReason
        let (visible, reason, path) = visibilityDecision()

        if visible != prevVisible {
            // Suppress logging an "INVISIBLE" transition inside the initial grace period.
            let inGrace = inInitialGracePeriod()
            if visible {
                invisibleConsecutiveFrames = 0
                invisibilityBeganTime = nil
                pendingVisibilityReinit = true
                fullyReleasedAfterLongInvisibility = false
                os_log(
                    "Visibility transition -> VISIBLE (frame #%{public}llu) reason=%{public}@ prevReason=%{public}@ decisionPath=%{public}@",
                    log: log!,
                    type: .info,
                    frameIndex,
                    reason,
                    prevReason,
                    path
                )
            } else if !inGrace {
                invisibilityBeganTime = CACurrentMediaTime()
                os_log(
                    "Visibility transition -> INVISIBLE (frame #%{public}llu) reason=%{public}@ prevReason=%{public}@ decisionPath=%{public}@",
                    log: log!,
                    type: .info,
                    frameIndex,
                    reason,
                    prevReason,
                    path
                )
            }
            lastVisibilityState = visible
            // Reset last logged markers so next periodic log (if any) can output
            lastLoggedVisibilityState = nil
            lastLoggedVisibilityReason = nil
        }
        lastVisibilityReason = reason
        lastVisibilityDecisionPath = path

        // Decide whether to log the periodic line (suppress after long-term stable invisibility unless reason/state change)
        var shouldLogPeriodic = logEveryCheck
        if logEveryCheck {
            if !visible {
                if let start = invisibilityBeganTime {
                    let elapsed = CACurrentMediaTime() - start
                    if elapsed >= invisibilityFullReleaseThresholdSeconds {
                        // Suppress if unchanged
                        if lastLoggedVisibilityState == visible
                            && lastLoggedVisibilityReason == reason
                        {
                            shouldLogPeriodic = false
                        }
                    }
                }
            }
        }

        if shouldLogPeriodic {
            os_log(
                "visibilityCheck periodic frame #%{public}llu visible=%{public}@ reason=%{public}@ decisionPath=%{public}@",
                log: log!,
                type: .info,
                frameIndex,
                visible ? "yes" : "no",
                reason,
                path
            )
            lastLoggedVisibilityState = visible
            lastLoggedVisibilityReason = reason
        }

        if !lastVisibilityState {
            invisibleConsecutiveFrames &+= 1
            if let start = invisibilityBeganTime {
                let elapsed = CACurrentMediaTime() - start
                // Partial release (Metal layer + renderer) after short threshold
                if elapsed >= visibilityReleaseResourcesThresholdSeconds
                    && !resourcesReleasedWhileInvisible
                {
                    deallocateResourcesPartial(
                        reason: String(format: "Invisible %.2fs", elapsed)
                    )
                }
                // Full release (engine too) after long threshold
                if elapsed >= invisibilityFullReleaseThresholdSeconds
                    && !fullyReleasedAfterLongInvisibility
                {
                    os_log(
                        "Long-term invisibility (%.2fs) -> full resource release",
                        log: log!,
                        type: .info,
                        elapsed
                    )
                    deallocateResources()
                    resourcesReleasedWhileInvisible = true  // ensure recreate on visibility
                    fullyReleasedAfterLongInvisibility = true
                }
            }
        }
    }

    private func inInitialGracePeriod() -> Bool {
        guard let t0 = firstAnimationWallTime else { return true }
        return (CACurrentMediaTime() - t0) < initialVisibilityGraceSeconds
    }

    // Build a decision with a detailed path of evaluated checks.
    private func visibilityDecision() -> (Bool, String, String) {
        var steps: [String] = []

        func finish(_ visible: Bool, _ reason: String) -> (Bool, String, String)
        {
            steps.append(
                "FINAL=\(visible ? "VISIBLE" : "INVISIBLE") reason=\(reason)"
            )
            return (visible, reason, steps.joined(separator: " -> "))
        }

        steps.append("BEGIN")
        if isPreview {
            steps.append("mode=preview")
            guard let win = window else {
                steps.append("window=nil -> assume visible preview")
                return finish(true, "preview-no-window-assume")
            }
            if win.isMiniaturized {
                steps.append("miniaturized=true")
                return finish(false, "preview-miniaturized")
            }
            if !win.isVisible {
                steps.append("win.isVisible=false")
                return finish(false, "preview-notVisible")
            }
            steps.append("preview-visible=true")
            return finish(true, "preview-visible")
        }

        let grace = inInitialGracePeriod()
        steps.append("grace=\(grace)")

        guard let win = window else {
            steps.append("window=nil")
            if grace {
                steps.append("grace optimistic -> visible")
                return finish(true, "grace-no-window")
            }
            return finish(false, "no-window")
        }

        if win.isMiniaturized {
            steps.append("miniaturized=true")
            return finish(false, "miniaturized")
        }

        if !win.isVisible {
            steps.append("win.isVisible=false")
            if grace {
                steps.append("grace optimistic -> visible")
                return finish(true, "grace-notVisibleFlag")
            }
            return finish(false, "window-notVisible-flag")
        }

        let occ = win.occlusionState
        steps.append("occlusionState=\(describeOcclusion(occ))")

        // If .visible not set we treat as ambiguous (older SDK may not provide .occluded)
        if !occ.contains(.visible) {
            steps.append(".visible bit NOT set -> ambiguous")
            if grace {
                steps.append("grace optimistic -> visible")
                return finish(true, "grace-ambiguous-occlusion")
            }
            let cgOnscreen = cgWindowIsOnScreenThrottled(frameIndex: frameIndex)
            steps.append("CGWindow onscreen=\(cgOnscreen)")
            if cgOnscreen {
                return finish(true, "cgWindow-onscreen-ambiguousOcc")
            } else {
                return finish(false, "cgWindow-offscreen-ambiguousOcc")
            }
        }

        // Screen intersection
        let wf = win.frame
        let intersects = NSScreen.screens.contains {
            NSIntersectsRect($0.frame, wf)
        }
        steps.append("screenIntersect=\(intersects)")
        if !intersects {
            if grace {
                steps.append("grace optimistic -> visible")
                return finish(true, "grace-offscreen-frame")
            }
            return finish(false, "no-screen-intersection")
        }

        return finish(true, "visible-occlusionState-visibleBit")
    }

    private func describeOcclusion(_ state: NSWindow.OcclusionState) -> String {
        var parts: [String] = []
        if state.contains(.visible) { parts.append("visible") }
        if parts.isEmpty { parts.append("none") }
        return parts.joined(separator: "|")
    }

    private func cgWindowIsOnScreenThrottled(frameIndex: UInt64) -> Bool {
        if frameIndex - lastCGWindowCheckFrame < cgWindowRecheckIntervalFrames {
            return cachedCGWindowOnscreen
        }
        lastCGWindowCheckFrame = frameIndex
        guard let win = window else { return cachedCGWindowOnscreen }
        let wid = CGWindowID(win.windowNumber)
        guard wid != 0 else { return cachedCGWindowOnscreen }
        if let infoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            wid
        ) as? [[String: Any]],
            let info = infoList.first
        {
            if let onscreen = info[kCGWindowIsOnscreen as String] as? Bool {
                cachedCGWindowOnscreen = onscreen
                return onscreen
            }
        }
        return cachedCGWindowOnscreen
    }

    private func shouldRenderCurrentFrame() -> Bool {
        if !lastVisibilityState { return false }
        if !rendererDrawableAvailable { return false }
        return true
    }
}
