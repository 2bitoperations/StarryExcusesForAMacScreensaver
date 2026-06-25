import CoreGraphics
import ScreenSaver
import QuartzCore
import os.log

// ---------------------------------------------------------------------------
// C FFI declarations — resolved at load time from libstarry_saver.dylib
// which is embedded in Contents/Frameworks/ and located via the rpath
// @loader_path/../Frameworks baked in by build-saver.sh.
// ---------------------------------------------------------------------------

@_silgen_name("starry_create")
private func starry_create(
    _ layer: UnsafeMutableRawPointer,
    _ width: UInt32,
    _ height: UInt32
) -> UnsafeMutableRawPointer?

@_silgen_name("starry_frame")
private func starry_frame(_ handle: UnsafeMutableRawPointer)

@_silgen_name("starry_resize")
private func starry_resize(
    _ handle: UnsafeMutableRawPointer,
    _ width: UInt32,
    _ height: UInt32
)

@_silgen_name("starry_destroy")
private func starry_destroy(_ handle: UnsafeMutableRawPointer)

// ---------------------------------------------------------------------------

private let log = Logger(
    subsystem: "com.2bitoperations.screensaver.StarryNightRust",
    category: "StarrySaverView"
)

// @objc(StarrySaverView) pins the Objective-C runtime name to the bare
// class name so NSPrincipalClass = "StarrySaverView" in Info.plist works
// regardless of the Swift module name.
@objc(StarrySaverView)
class StarrySaverView: ScreenSaverView {
    private var renderHandle: UnsafeMutableRawPointer?
    // The CAMetalLayer is a sublayer of self.layer (the view's regular CALayer
    // backing).  Using makeBackingLayer() to return a CAMetalLayer directly does
    // NOT work in the legacyScreenSaver.appex host — the host manages the backing
    // layer itself and our Metal frames are never composited to screen.  The
    // working pattern (mirrored from StarryExcuseForAView.swift) is wantsLayer=true
    // plus an explicit CAMetalLayer sublayer added in startAnimation.
    private var metalLayer: CAMetalLayer?

    // MARK: - Visibility state (ported from StarryExcuseForAView.swift)

    private var stoppedRunning = false
    private var firstAnimationWallTime: CFTimeInterval?
    private let initialVisibilityGraceSeconds: Double = 1.5
    private var lastVisibilityState: Bool = true
    private var lastVisibilityReason: String = "initial"
    private var lastVisibilityDecisionPath: String = "initial"
    private var lastLoggedVisibilityState: Bool?
    private var lastLoggedVisibilityReason: String?
    private var invisibilityBeganTime: CFTimeInterval?
    private var invisibleConsecutiveFrames: UInt64 = 0
    private let visibilityReleaseThresholdSeconds: Double = 3.0
    private var resourcesReleasedWhileInvisible = false
    private let visibilityCheckIntervalSeconds: CFTimeInterval = 2.0
    private var lastVisibilityCheckWallTime: CFTimeInterval = 0
    private var lastCGWindowCheckFrame: UInt64 = 0
    private var cachedCGWindowOnscreen: Bool = true
    private let cgWindowRecheckIntervalFrames: UInt64 = 30

    // Lazy so the panel is created on demand and lives for the view's lifetime.
    private lazy var configPanel: NSWindow = makeConfigPanel()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        log.info("init \(Int(frame.width))×\(Int(frame.height)) isPreview=\(isPreview) build=\(buildCommit, privacy: .public)")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
    }

    override func startAnimation() {
        super.startAnimation()
        stoppedRunning = false
        firstAnimationWallTime = CACurrentMediaTime()
        log.info("startAnimation \(Int(self.bounds.width))×\(Int(self.bounds.height)) pts")
        registerListeners()
        guard renderHandle == nil else { return }

        // Set wantsLayer here (not in init) so the backing layer is created
        // while the view is already in a window — the same order used by
        // StarryExcuseForAView.swift:457.  Setting it in init produces a layer
        // that isn't wired to the window-server compositor.
        wantsLayer = true

        let scale = window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0

        let mLayer: CAMetalLayer
        if let existing = metalLayer {
            mLayer = existing
        } else {
            mLayer = CAMetalLayer()
            mLayer.frame = bounds
            mLayer.contentsScale = scale
            mLayer.isOpaque = true
            layer?.addSublayer(mLayer)
            metalLayer = mLayer
            log.info("CAMetalLayer sublayer added layer=\(self.layer != nil) contentsScale=\(scale)")
        }

        // Pass physical pixel dimensions (points × backingScaleFactor) — the
        // same pattern used by StarryExcuseForAView.swift lines 344-350.
        let wPx = UInt32(max(bounds.width  * scale, 1))
        let hPx = UInt32(max(bounds.height * scale, 1))
        log.info("starry_create \(wPx)×\(hPx) px @ \(scale)x scale")
        renderHandle = starry_create(
            Unmanaged.passUnretained(mLayer).toOpaque(), wPx, hPx
        )
        if renderHandle == nil {
            log.error("starry_create returned nil — GPU init failed")
        } else {
            log.info("starry_create OK")
        }

        if let win = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: win
            )
        }
    }

    override func stopAnimation() {
        log.info("stopAnimation")
        stoppedRunning = true
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        DistributedNotificationCenter.default().removeObserver(self)
        releaseResources()
        super.stopAnimation()
    }

    private func releaseResources() {
        if let h = renderHandle {
            starry_destroy(h)
            renderHandle = nil
        }
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        resourcesReleasedWhileInvisible = true
    }

    private func recreateResources() {
        guard resourcesReleasedWhileInvisible, !stoppedRunning else { return }
        log.info("recreateResources: visibility restored, recreating GPU context")
        resourcesReleasedWhileInvisible = false
        invisibilityBeganTime = nil
        invisibleConsecutiveFrames = 0

        wantsLayer = true
        let scale = window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let mLayer = CAMetalLayer()
        mLayer.frame = bounds
        mLayer.contentsScale = scale
        mLayer.isOpaque = true
        layer?.addSublayer(mLayer)
        metalLayer = mLayer

        let wPx = UInt32(max(bounds.width  * scale, 1))
        let hPx = UInt32(max(bounds.height * scale, 1))
        log.info("recreateResources starry_create \(wPx)×\(hPx) px")
        renderHandle = starry_create(
            Unmanaged.passUnretained(mLayer).toOpaque(), wPx, hPx
        )
        if renderHandle == nil {
            log.error("recreateResources: starry_create returned nil")
        } else {
            log.info("recreateResources OK")
        }
    }

    private var frameCount: UInt64 = 0

    override func animateOneFrame() {
        guard !stoppedRunning else { return }
        frameCount += 1
        if frameCount == 1 || frameCount % 300 == 0 {
            log.info("animateOneFrame #\(self.frameCount) window=\(self.window != nil)")
        }

        let now = CACurrentMediaTime()
        if now - lastVisibilityCheckWallTime >= visibilityCheckIntervalSeconds {
            lastVisibilityCheckWallTime = now
            inferVisibilityState(frameIndex: frameCount, logEveryCheck: true)
        }

        guard shouldRenderCurrentFrame() else { return }

        if resourcesReleasedWhileInvisible {
            recreateResources()
            return
        }

        guard let hdl = renderHandle else { return }
        starry_frame(hdl)
    }

    // MARK: - Visibility notifications

    private func registerListeners() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(willStopHandler(_:)),
            name: Notification.Name("com.apple.screensaver.willstop"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(willStopHandler(_:)),
            name: Notification.Name("com.apple.screensaver.didstop"),
            object: nil
        )
    }

    @objc private func willStopHandler(_ note: Notification) {
        if !isPreview {
            log.info("willStop/didStop received — terminating process")
            NSApplication.shared.terminate(nil)
        } else {
            log.info("willStop/didStop received (preview) — ignoring terminate")
        }
    }

    @objc private func windowOcclusionChanged(_ note: Notification) {
        inferVisibilityState(frameIndex: frameCount, logEveryCheck: true)
    }

    // MARK: - Visibility inference (ported from StarryExcuseForAView.swift)

    private func shouldRenderCurrentFrame() -> Bool {
        lastVisibilityState
    }

    private func inInitialGracePeriod() -> Bool {
        guard let t0 = firstAnimationWallTime else { return true }
        return (CACurrentMediaTime() - t0) < initialVisibilityGraceSeconds
    }

    private func inferVisibilityState(frameIndex: UInt64, logEveryCheck: Bool = false) {
        let prevVisible = lastVisibilityState
        let prevReason = lastVisibilityReason
        let (visible, reason, path) = visibilityDecision()

        if visible != prevVisible {
            if visible {
                invisibleConsecutiveFrames = 0
                invisibilityBeganTime = nil
                log.info("visibility → VISIBLE frame=#\(frameIndex) reason=\(reason, privacy: .public) prev=\(prevReason, privacy: .public) path=\(path, privacy: .public)")
            } else if !inInitialGracePeriod() {
                invisibilityBeganTime = CACurrentMediaTime()
                log.info("visibility → INVISIBLE frame=#\(frameIndex) reason=\(reason, privacy: .public) prev=\(prevReason, privacy: .public) path=\(path, privacy: .public)")
            }
            lastVisibilityState = visible
            lastLoggedVisibilityState = nil
            lastLoggedVisibilityReason = nil
        }
        lastVisibilityReason = reason
        lastVisibilityDecisionPath = path

        if logEveryCheck {
            if lastLoggedVisibilityState != visible || lastLoggedVisibilityReason != reason {
                log.info("visibilityCheck frame=#\(frameIndex) visible=\(visible) reason=\(reason, privacy: .public)")
                lastLoggedVisibilityState = visible
                lastLoggedVisibilityReason = reason
            }
        }

        if !lastVisibilityState {
            invisibleConsecutiveFrames &+= 1
            if let start = invisibilityBeganTime {
                let elapsed = CACurrentMediaTime() - start
                if elapsed >= visibilityReleaseThresholdSeconds, !resourcesReleasedWhileInvisible {
                    log.info("Long invisibility (\(String(format: "%.1f", elapsed))s) — releasing GPU resources")
                    releaseResources()
                }
            }
        }
    }

    private func visibilityDecision() -> (Bool, String, String) {
        var steps: [String] = ["BEGIN"]

        func finish(_ visible: Bool, _ reason: String) -> (Bool, String, String) {
            steps.append("FINAL=\(visible ? "VISIBLE" : "INVISIBLE") reason=\(reason)")
            return (visible, reason, steps.joined(separator: " -> "))
        }

        if isPreview {
            steps.append("mode=preview")
            guard let win = window else { return finish(true, "preview-no-window-assume") }
            if win.isMiniaturized { return finish(false, "preview-miniaturized") }
            if !win.isVisible    { return finish(false, "preview-notVisible") }
            return finish(true, "preview-visible")
        }

        let grace = inInitialGracePeriod()
        steps.append("grace=\(grace)")

        guard let win = window else {
            if grace { return finish(true, "grace-no-window") }
            return finish(false, "no-window")
        }

        if win.isMiniaturized {
            steps.append("miniaturized=true")
            return finish(false, "miniaturized")
        }

        if !win.isVisible {
            steps.append("win.isVisible=false")
            if grace { return finish(true, "grace-notVisibleFlag") }
            return finish(false, "window-notVisible-flag")
        }

        let occ = win.occlusionState
        steps.append("occlusionState=\(occ.contains(.visible) ? "visible" : "none")")

        if !occ.contains(.visible) {
            if grace { return finish(true, "grace-ambiguous-occlusion") }
            let onScreen = cgWindowIsOnScreenThrottled(frameIndex: frameCount)
            steps.append("CGWindow=\(onScreen)")
            return onScreen
                ? finish(true,  "cgWindow-onscreen-ambiguousOcc")
                : finish(false, "cgWindow-offscreen-ambiguousOcc")
        }

        let wf = win.frame
        let intersects = NSScreen.screens.contains { NSIntersectsRect($0.frame, wf) }
        steps.append("screenIntersect=\(intersects)")
        if !intersects {
            if grace { return finish(true, "grace-offscreen-frame") }
            return finish(false, "no-screen-intersection")
        }

        return finish(true, "visible-occlusionState-visibleBit")
    }

    private func cgWindowIsOnScreenThrottled(frameIndex: UInt64) -> Bool {
        if frameIndex - lastCGWindowCheckFrame < cgWindowRecheckIntervalFrames {
            return cachedCGWindowOnscreen
        }
        lastCGWindowCheckFrame = frameIndex
        guard let win = window else { return cachedCGWindowOnscreen }
        let wid = CGWindowID(win.windowNumber)
        guard wid != 0 else { return cachedCGWindowOnscreen }
        if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid)
            as? [[String: Any]],
           let info = list.first,
           let onScreen = info[kCGWindowIsOnscreen as String] as? Bool
        {
            cachedCGWindowOnscreen = onScreen
            return onScreen
        }
        return cachedCGWindowOnscreen
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer?.frame = bounds
        guard let hdl = renderHandle else { return }
        let scale = metalLayer?.contentsScale ?? 1.0
        let wPx = UInt32(max(newSize.width  * scale, 1))
        let hPx = UInt32(max(newSize.height * scale, 1))
        log.debug("setFrameSize \(Int(newSize.width))×\(Int(newSize.height)) pts @\(scale)x → \(wPx)×\(hPx) px")
        starry_resize(hdl, wPx, hPx)
    }

    // MARK: - Options panel

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? { configPanel }

    @objc private func closeConfigPanel(_ sender: Any?) {
        configPanel.sheetParent?.endSheet(configPanel)
    }

    private func makeConfigPanel() -> NSWindow {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Starry Night (Rust)"

        let label = NSTextField(wrappingLabelWithString:
            "Starry Night · Rust/wgpu port · build \(buildCommit)\n" +
            "A dedicated preferences UI is planned for a future release."
        )
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "OK", target: self, action: #selector(closeConfigPanel))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.keyEquivalent = "\r"

        let cv = panel.contentView!
        cv.addSubview(label)
        cv.addSubview(button)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            button.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
        return panel
    }
}
