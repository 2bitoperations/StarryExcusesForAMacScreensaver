import CoreGraphics
import Darwin  // For task_info CPU sampling
import Foundation
import QuartzCore  // For CACurrentMediaTime()
import os
import simd

// Building lights spawning now mirrors star spawning logic:
// A normalized fraction (0.0–1.0) -> fraction of reference max density (600 lights/sec @ 3008x1692).
// No legacy per-update or explicit per-second override retained.

struct StarryRuntimeConfig {
    var buildingHeight: Double
    var buildingFrequency: Double
    var secsBetweenClears: Double
    var moonTraversalMinutes: Int
    var moonDiameterScreenWidthPercent: Double
    var moonBrightBrightness: Double
    var moonDarkBrightness: Double
    var moonPhaseOverrideEnabled: Bool
    var moonPhaseOverrideValue: Double
    var traceEnabled: Bool
    var showLightAreaTextureFillMask: Bool

    var shootingStarsEnabled: Bool
    var shootingStarsAvgSeconds: Double
    var shootingStarsDirectionMode: Int
    var shootingStarsLength: Double
    var shootingStarsSpeed: Double
    var shootingStarsThickness: Double
    var shootingStarsBrightness: Double
    var shootingStarsDebugShowSpawnBounds: Bool  // Used for BOTH shooting stars & satellites spawn bounds

    var satellitesEnabled: Bool = true
    var satellitesAvgSpawnSeconds: Double = 0.75
    var satellitesSpeed: Double = 90.0
    var satellitesSize: Double = 2.0
    var satellitesBrightness: Double = 0.9
    var satellitesTrailing: Bool = true

    var debugOverlayEnabled: Bool = false

    var debugDropBaseEveryNFrames: Int = 0
    var debugForceClearEveryNFrames: Int = 0
    var debugLogEveryFrame: Bool = false

    // NEW: Normalized (0..1) fraction of maximum building lights density.
    var buildingLightsSpawnPerSecFractionOfMax: Double = 0
    var disableFlasherOnBase: Bool = false

    // Existing (already refactored) star density fraction.
    var starSpawnPerSecFractionOfMax: Double = 0
}

extension StarryRuntimeConfig: CustomStringConvertible {
    var description: String {
        return """
            StarryRuntimeConfig(
              buildingHeight: \(buildingHeight),
              buildingFrequency: \(buildingFrequency),
              secsBetweenClears: \(secsBetweenClears),
              moonTraversalMinutes: \(moonTraversalMinutes),
              moonDiameterScreenWidthPercent: \(moonDiameterScreenWidthPercent),
              moonBrightBrightness: \(moonBrightBrightness),
              moonDarkBrightness: \(moonDarkBrightness),
              moonPhaseOverrideEnabled: \(moonPhaseOverrideEnabled),
              moonPhaseOverrideValue: \(moonPhaseOverrideValue),
              traceEnabled: \(traceEnabled),
              showLightAreaTextureFillMask: \(showLightAreaTextureFillMask),
              shootingStarsEnabled: \(shootingStarsEnabled),
              shootingStarsAvgSeconds: \(shootingStarsAvgSeconds),
              shootingStarsDirectionMode: \(shootingStarsDirectionMode),
              shootingStarsLength: \(shootingStarsLength),
              shootingStarsSpeed: \(shootingStarsSpeed),
              shootingStarsThickness: \(shootingStarsThickness),
              shootingStarsBrightness: \(shootingStarsBrightness),
              shootingStarsDebugShowSpawnBounds: \(shootingStarsDebugShowSpawnBounds),
              satellitesEnabled: \(satellitesEnabled),
              satellitesAvgSpawnSeconds: \(satellitesAvgSpawnSeconds),
              satellitesSpeed: \(satellitesSpeed),
              satellitesSize: \(satellitesSize),
              satellitesBrightness: \(satellitesBrightness),
              satellitesTrailing: \(satellitesTrailing),
              debugOverlayEnabled: \(debugOverlayEnabled),
              debugDropBaseEveryNFrames: \(debugDropBaseEveryNFrames),
              debugForceClearEveryNFrames: \(debugForceClearEveryNFrames),
              debugLogEveryFrame: \(debugLogEveryFrame),
              buildingLightsSpawnPerSecFractionOfMax: \(buildingLightsSpawnPerSecFractionOfMax),
              disableFlasherOnBase: \(disableFlasherOnBase),
              starSpawnPerSecFractionOfMax: \(starSpawnPerSecFractionOfMax)
            )
            """
    }
}

final class StarryEngine {
    private let log: OSLog
    private(set) var config: StarryRuntimeConfig

    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var shootingStarsRenderer: ShootingStarsLayerRenderer?
    private var satellitesRenderer: SatellitesLayerRenderer?

    private var size: CGSize
    private var lastInitSize: CGSize

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    private var fpsAccumulatedTime: CFTimeInterval = 0
    private var fpsFrameCount: Int = 0
    private var currentFPS: Double = 0

    private var lastProcessCPUTimesSeconds: Double = 0
    private var lastCPUSampleWallTime: CFTimeInterval = 0
    private var currentCPUPercent: Double = 0

    private var moonAlbedoImage: CGImage?
    private var moonAlbedoDirty: Bool = false

    private var previewMetalRenderer: StarryMetalRenderer?

    private var engineFrameIndex: UInt64 = 0
    private var verboseLogging: Bool = true
    private var engineLogEveryNFrames: Int = 50
    private var forceClearOnNextFrame: Bool = false

    private var observersInstalled: Bool = false
    private let diagnosticsNotification = Notification.Name("StarryDiagnostics")
    private let clearNotification = Notification.Name("StarryClear")

    // Reference resolution.
    private let referenceWidth: Double = 3008.0
    private let referenceHeight: Double = 1692.0

    // Maximum per-pixel fractions (at fraction=1.0) for stars & building lights.
    // 1600 stars/sec @ reference -> fraction-of-pixels
    private lazy var maxStarSpawnFractionOfPixels: Double = {
        1600.0 / (referenceWidth * referenceHeight)
    }()
    // 600 building lights/sec @ reference
    private lazy var maxBuildingLightsSpawnFractionOfPixels: Double = {
        600.0 / (referenceWidth * referenceHeight)
    }()

    init(
        size: CGSize,
        log: OSLog,
        config: StarryRuntimeConfig
    ) {
        self.size = size
        self.lastInitSize = size
        self.log = log
        self.config = config

        os_log(
            "StarryEngine initialized with config:\n%{public}@",
            log: log,
            type: .info,
            config.description
        )
        os_log(
            "Initial size: %{public}.0fx%{public}.0f",
            log: log,
            type: .info,
            Double(size.width),
            Double(size.height)
        )

        forceClearOnNextFrame = true
        os_log(
            "Engine init: will force clear on next frame to reset accumulation textures",
            log: log,
            type: .info
        )

        installNotificationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func installNotificationObservers() {
        guard !observersInstalled else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDiagnosticsNotification(_:)),
            name: diagnosticsNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClearNotification(_:)),
            name: clearNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDiagnosticsNotification(_:)),
            name: diagnosticsNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleClearNotification(_:)),
            name: clearNotification,
            object: nil
        )
        observersInstalled = true
    }

    @objc private func handleDiagnosticsNotification(_ note: Notification) {
        let ui = note.userInfo
        var applied: [String] = []
        var cfg = config
        var cfgChanged = false

        // (Legacy building lights keys intentionally ignored / removed.)

        if let n: Int = value("dropBaseEveryN", from: ui),
            n != config.debugDropBaseEveryNFrames
        {
            cfg.debugDropBaseEveryNFrames = max(0, n)
            applied.append("dropBaseEveryN=\(cfg.debugDropBaseEveryNFrames)")
            cfgChanged = true
        }
        if let b: Bool = value("debugLogEveryFrame", from: ui),
            b != config.debugLogEveryFrame
        {
            cfg.debugLogEveryFrame = b
            applied.append("debugLogEveryFrame=\(b)")
            cfgChanged = true
        }
        if let n: Int = value("debugLogEveryN", from: ui) {
            engineLogEveryNFrames = max(0, n)
            applied.append("engine.debugLogEveryN=\(engineLogEveryNFrames)")
        }
        if let b: Bool = value("forceClearOnNextFrame", from: ui), b {
            forceClearOnNextFrame = true
            applied.append("forceClearOnNextFrame=true")
        }
        if let b: Bool = value("disableFlasherOnBase", from: ui),
            b != config.disableFlasherOnBase
        {
            cfg.disableFlasherOnBase = b
            applied.append("disableFlasherOnBase=\(b)")
            cfgChanged = true
        }
        if let b: Bool = value("shootingStarsDebugShowSpawnBounds", from: ui),
            b != config.shootingStarsDebugShowSpawnBounds
        {
            cfg.shootingStarsDebugShowSpawnBounds = b
            applied.append("shootingStarsDebugShowSpawnBounds=\(b)")
            cfgChanged = true
        }

        if cfgChanged {
            updateConfig(cfg)
        }
        if applied.isEmpty {
            os_log(
                "Engine Diagnostics notification: no applicable keys",
                log: log,
                type: .info
            )
        } else {
            os_log(
                "Engine Diagnostics applied: %{public}@",
                log: log,
                type: .info,
                applied.joined(separator: ", ")
            )
        }
    }

    @objc private func handleClearNotification(_ note: Notification) {
        let target: String =
            (note.userInfo?["target"] as? String)?.lowercased() ?? "all"
        switch target {
        case "all":
            os_log(
                "Engine Clear: ALL — resetting state and scheduling renderer clear",
                log: log,
                type: .info
            )
            skyline = nil
            skylineRenderer = nil
            satellitesRenderer = nil
            shootingStarsRenderer = nil
            forceClearOnNextFrame = true
        case "base":
            os_log(
                "Engine Clear: BASE — resetting skyline frame counter and scheduling renderer base clear",
                log: log,
                type: .info
            )
            skylineRenderer?.resetFrameCounter()
            forceClearOnNextFrame = true
        case "satellites":
            os_log(
                "Engine Clear: SATELLITES — resetting satellites simulation",
                log: log,
                type: .info
            )
            satellitesRenderer?.reset()
        case "shooting":
            os_log(
                "Engine Clear: SHOOTING — resetting shooting-stars simulation",
                log: log,
                type: .info
            )
            shootingStarsRenderer?.reset()
        default:
            os_log(
                "Engine Clear: unknown target '%{public}@' — treating as ALL",
                log: log,
                type: .error,
                target
            )
            skyline = nil
            skylineRenderer = nil
            satellitesRenderer = nil
            shootingStarsRenderer = nil
            forceClearOnNextFrame = true
        }
    }

    func resizeIfNeeded(newSize: CGSize) {
        guard newSize != lastInitSize, newSize.width > 0, newSize.height > 0
        else { return }
        os_log(
            "Resize: %{public}.0fx%{public}.0f -> %{public}.0fx%{public}.0f",
            log: log,
            type: .info,
            Double(lastInitSize.width),
            Double(lastInitSize.height),
            Double(newSize.width),
            Double(newSize.height)
        )
        size = newSize
        lastInitSize = newSize

        skyline = nil
        skylineRenderer = nil
        shootingStarsRenderer = nil
        satellitesRenderer = nil

        moonAlbedoImage = nil
        moonAlbedoDirty = false
        forceClearOnNextFrame = true
    }

    func updateConfig(_ newConfig: StarryRuntimeConfig) {
        let skylineAffecting =
            config.buildingHeight != newConfig.buildingHeight
            || config.buildingFrequency != newConfig.buildingFrequency
            || config.moonTraversalMinutes != newConfig.moonTraversalMinutes
            || config.moonDiameterScreenWidthPercent
                != newConfig.moonDiameterScreenWidthPercent
            || config.moonBrightBrightness != newConfig.moonBrightBrightness
            || config.moonDarkBrightness != newConfig.moonDarkBrightness
            || config.moonPhaseOverrideEnabled
                != newConfig.moonPhaseOverrideEnabled
            || config.moonPhaseOverrideValue != newConfig.moonPhaseOverrideValue
            || config.showLightAreaTextureFillMask
                != newConfig.showLightAreaTextureFillMask
            || config.starSpawnPerSecFractionOfMax
                != newConfig.starSpawnPerSecFractionOfMax
            || config.buildingLightsSpawnPerSecFractionOfMax
                != newConfig.buildingLightsSpawnPerSecFractionOfMax

        if skylineAffecting {
            os_log(
                "Config changed (skyline affecting) — resetting skyline, renderers, and moon albedo",
                log: log,
                type: .info
            )
            skyline = nil
            skylineRenderer = nil
            previewMetalRenderer = nil
            moonAlbedoImage = nil
            moonAlbedoDirty = false
        }

        let shootingStarsAffecting =
            config.shootingStarsEnabled != newConfig.shootingStarsEnabled
            || config.shootingStarsAvgSeconds
                != newConfig.shootingStarsAvgSeconds
            || config.shootingStarsDirectionMode
                != newConfig.shootingStarsDirectionMode
            || config.shootingStarsLength != newConfig.shootingStarsLength
            || config.shootingStarsSpeed != newConfig.shootingStarsSpeed
            || config.shootingStarsThickness != newConfig.shootingStarsThickness
            || config.shootingStarsBrightness
                != newConfig.shootingStarsBrightness
            || config.shootingStarsDebugShowSpawnBounds
                != newConfig.shootingStarsDebugShowSpawnBounds

        if shootingStarsAffecting {
            os_log(
                "Config changed (shooting-stars affecting) — resetting shootingStarsRenderer",
                log: log,
                type: .info
            )
            shootingStarsRenderer = nil
        }

        let satellitesAffecting =
            config.satellitesEnabled != newConfig.satellitesEnabled
            || config.satellitesAvgSpawnSeconds
                != newConfig.satellitesAvgSpawnSeconds
            || config.satellitesSpeed != newConfig.satellitesSpeed
            || config.satellitesSize != newConfig.satellitesSize
            || config.satellitesBrightness != newConfig.satellitesBrightness
            || config.satellitesTrailing != newConfig.satellitesTrailing
            // Re-use the shootingStarsDebugShowSpawnBounds flag to also control satellite bounds
            || config.shootingStarsDebugShowSpawnBounds
                != newConfig.shootingStarsDebugShowSpawnBounds

        if satellitesAffecting {
            os_log(
                "Config changed (satellites affecting) — resetting satellitesRenderer",
                log: log,
                type: .info
            )
            satellitesRenderer = nil
        }

        let diagnosticsChanged =
            config.debugDropBaseEveryNFrames
            != newConfig.debugDropBaseEveryNFrames
            || config.debugForceClearEveryNFrames
                != newConfig.debugForceClearEveryNFrames
            || config.debugLogEveryFrame != newConfig.debugLogEveryFrame
            || config.disableFlasherOnBase != newConfig.disableFlasherOnBase
        if diagnosticsChanged {
            os_log(
                "Diagnostics config changed: dropBaseEveryN=%{public}d, forceClearEveryN=%{public}d, logEveryFrame=%{public}@, disableFlasherOnBase=%{public}@",
                log: log,
                type: .info,
                newConfig.debugDropBaseEveryNFrames,
                newConfig.debugForceClearEveryNFrames,
                newConfig.debugLogEveryFrame ? "true" : "false",
                newConfig.disableFlasherOnBase ? "true" : "false"
            )
        }

        let overlayChanged =
            (config.debugOverlayEnabled != newConfig.debugOverlayEnabled)
        if overlayChanged {
            os_log(
                "Debug overlay toggled: %{public}@",
                log: log,
                type: .info,
                newConfig.debugOverlayEnabled ? "ENABLED" : "disabled"
            )
        }

        config = newConfig
        os_log(
            "New config applied (starFraction=%.4f -> starsEff=%.2f/s | buildingLightsFraction=%.4f -> lightsEff=%.2f/s)",
            log: log,
            type: .info,
            config.starSpawnPerSecFractionOfMax,
            effectiveStarsPerSecond(),
            config.buildingLightsSpawnPerSecFractionOfMax,
            effectiveBuildingLightsPerSecond()
        )

        if let sr = skylineRenderer {
            sr.setDisableFlasherOnBase(config.disableFlasherOnBase)
            // Update per-second rates on existing renderer
            sr.updateRates(
                starsPerSecond: effectiveStarsPerSecond(),
                buildingLightsPerSecond: effectiveBuildingLightsPerSecond()
            )
        }

        // Propagate overlay gating to layer renderers if necessary
        if overlayChanged {
            shootingStarsRenderer?.setDebugOverlayEnabled(
                config.debugOverlayEnabled
            )
            satellitesRenderer?.setDebugOverlayEnabled(
                config.debugOverlayEnabled
            )
        }

        if skylineAffecting || shootingStarsAffecting || satellitesAffecting {
            forceClearOnNextFrame = true
            os_log(
                "Config change will force full clear on next frame",
                log: log,
                type: .info
            )
        }
    }

    private func effectiveStarsPerSecond() -> Double {
        let norm = max(0.0, min(config.starSpawnPerSecFractionOfMax, 1.0))
        let perPixelFraction = norm * maxStarSpawnFractionOfPixels
        return perPixelFraction * Double(size.width) * Double(size.height)
    }

    private func effectiveBuildingLightsPerSecond() -> Double {
        let norm = max(
            0.0,
            min(config.buildingLightsSpawnPerSecFractionOfMax, 1.0)
        )
        let perPixelFraction = norm * maxBuildingLightsSpawnFractionOfPixels
        return perPixelFraction * Double(size.width) * Double(size.height)
    }

    private func ensureSkyline() {
        guard skyline == nil || skylineRenderer == nil else {
            ensureSatellitesRenderer()
            ensureShootingStarsRenderer()
            return
        }
        os_log(
            "Initializing skyline/renderers for size %{public}dx%{public}d (starFraction=%.4f -> %.2f/s, buildingLightsFraction=%.4f -> %.2f/s)",
            log: log,
            type: .info,
            Int(size.width),
            Int(size.height),
            config.starSpawnPerSecFractionOfMax,
            effectiveStarsPerSecond(),
            config.buildingLightsSpawnPerSecFractionOfMax,
            effectiveBuildingLightsPerSecond()
        )
        do {
            let traversalSeconds = Double(config.moonTraversalMinutes) * 60.0

            // Temporary legacy per-update value retained only because Skyline initializer still expects it.
            // Will be removed when Skyline is refactored to rely solely on per-second rates.
            let legacyBuildingLightsPerUpdate = 15

            skyline = try Skyline(
                screenXMax: Int(size.width),
                screenYMax: Int(size.height),
                buildingHeightPercentMax: config.buildingHeight,
                buildingWidthMin: 40,
                buildingWidthMax: 300,
                buildingFrequency: config.buildingFrequency,
                buildingLightsPerUpdate: legacyBuildingLightsPerUpdate,
                buildingColor: Color(red: 0.972, green: 0.945, blue: 0.012),
                flasherRadius: 4,
                flasherPeriod: 2.0,
                log: log,
                clearAfterDuration: config.secsBetweenClears,
                traceEnabled: config.traceEnabled,
                moonTraversalSeconds: traversalSeconds,
                moonBrightBrightness: config.moonBrightBrightness,
                moonDarkBrightness: config.moonDarkBrightness,
                moonDiameterScreenWidthPercent: config
                    .moonDiameterScreenWidthPercent,
                moonPhaseOverrideEnabled: config.moonPhaseOverrideEnabled,
                moonPhaseOverrideValue: config.moonPhaseOverrideValue
            )
            if let skyline = skyline {
                os_log(
                    "Skyline created. dynamicStarsPerSec=%.2f (fraction=%.4f cap=%.8f) dynamicBuildingLightsPerSec=%.2f (fraction=%.4f cap=%.8f)",
                    log: log,
                    type: .info,
                    effectiveStarsPerSecond(),
                    config.starSpawnPerSecFractionOfMax,
                    maxStarSpawnFractionOfPixels,
                    effectiveBuildingLightsPerSecond(),
                    config.buildingLightsSpawnPerSecFractionOfMax,
                    maxBuildingLightsSpawnFractionOfPixels
                )
                skylineRenderer = SkylineCoreRenderer(
                    skyline: skyline,
                    log: log,
                    traceEnabled: config.traceEnabled,
                    disableFlasherOnBase: config.disableFlasherOnBase,
                    starsPerSecond: effectiveStarsPerSecond(),
                    buildingLightsPerSecond: effectiveBuildingLightsPerSecond()
                )
                os_log(
                    "SkylineCoreRenderer created (disableFlasherOnBase=%{public}@)",
                    log: log,
                    type: .info,
                    config.disableFlasherOnBase ? "true" : "false"
                )
                if let tex = skyline.getMoon()?.textureImage {
                    moonAlbedoImage = tex
                    moonAlbedoDirty = true
                    os_log(
                        "Fetched moon albedo image for GPU upload (size=%{public}dx%{public}d)",
                        log: log,
                        type: .info,
                        tex.width,
                        tex.height
                    )
                } else {
                    moonAlbedoImage = nil
                    moonAlbedoDirty = false
                    os_log(
                        "No moon albedo image available (yet)",
                        log: log,
                        type: .info
                    )
                }
            }
        } catch {
            os_log(
                "StarryEngine: unable to init skyline %{public}@",
                log: log,
                type: .fault,
                "\(error)"
            )
        }
        ensureSatellitesRenderer()
        ensureShootingStarsRenderer()
    }

    private func ensureShootingStarsRenderer() {
        guard shootingStarsRenderer == nil,
            config.shootingStarsEnabled,
            let skyline = skyline
        else { return }
        shootingStarsRenderer = ShootingStarsLayerRenderer(
            width: Int(size.width),
            height: Int(size.height),
            skyline: skyline,
            log: log,
            avgSeconds: config.shootingStarsAvgSeconds,
            directionModeRaw: config.shootingStarsDirectionMode,
            length: CGFloat(config.shootingStarsLength),
            speed: CGFloat(config.shootingStarsSpeed),
            thickness: CGFloat(config.shootingStarsThickness),
            brightness: CGFloat(config.shootingStarsBrightness),
            trailDecay: 1.0,
            debugShowSpawnBounds: config.shootingStarsDebugShowSpawnBounds,
            debugOverlayEnabled: config.debugOverlayEnabled
        )
        os_log(
            "ShootingStarsLayerRenderer created (enabled=%{public}@, avg=%{public}.2fs showBounds=%{public}@)",
            log: log,
            type: .info,
            config.shootingStarsEnabled ? "true" : "false",
            config.shootingStarsAvgSeconds,
            config.shootingStarsDebugShowSpawnBounds ? "true" : "false"
        )
    }

    private func ensureSatellitesRenderer() {
        guard satellitesRenderer == nil,
            config.satellitesEnabled,
            let skyline = skyline
        else { return }
        let flasher = skyline.getFlasherDetails()
        let flasherCenterY = flasher.map { CGFloat($0.centerY) }
        let flasherRadius = flasher.map { CGFloat($0.radius) }
        satellitesRenderer = SatellitesLayerRenderer(
            width: Int(size.width),
            height: Int(size.height),
            log: log,
            avgSpawnSeconds: config.satellitesAvgSpawnSeconds,
            speed: CGFloat(config.satellitesSpeed),
            size: CGFloat(config.satellitesSize),
            brightness: CGFloat(config.satellitesBrightness),
            trailing: config.satellitesTrailing,
            trailDecay: 1.0,
            debugShowSpawnBounds: config.shootingStarsDebugShowSpawnBounds,
            flasherCenterY: flasherCenterY,
            flasherRadius: flasherRadius,
            debugOverlayEnabled: config.debugOverlayEnabled
        )
        os_log(
            "SatellitesLayerRenderer created (enabled=%{public}@, avg=%{public}.2fs showBounds=%{public}@ flasher=%{public}@)",
            log: log,
            type: .info,
            config.satellitesEnabled ? "true" : "false",
            config.satellitesAvgSpawnSeconds,
            config.shootingStarsDebugShowSpawnBounds ? "true" : "false",
            (flasherCenterY != nil && flasherRadius != nil) ? "yes" : "no"
        )
    }

    // Decision helper: frame-level logs (per-frame or periodic) are only emitted when overlay is enabled.
    private func shouldEmitFrameLogs() -> Bool {
        return config.debugOverlayEnabled
    }

    func advanceFrameGPU() -> StarryDrawData {
        engineFrameIndex &+= 1

        if config.debugOverlayEnabled && config.debugForceClearEveryNFrames > 0
            && (engineFrameIndex % UInt64(config.debugForceClearEveryNFrames)
                == 0)
        {
            forceClearOnNextFrame = true
            os_log(
                "advanceFrameGPU: DIAG force clear scheduled for this frame (every N=%{public}d)",
                log: log,
                type: .info,
                config.debugForceClearEveryNFrames
            )
        }

        let allowFrameLogging = shouldEmitFrameLogs()
        let periodicLogThisFrame =
            allowFrameLogging && (engineLogEveryNFrames > 0)
            && (engineFrameIndex % UInt64(engineLogEveryNFrames) == 0)
        let logThisFrame =
            allowFrameLogging
            && (config.debugLogEveryFrame
                || (verboseLogging && periodicLogThisFrame))
        if logThisFrame {
            os_log(
                "advanceFrameGPU: begin frame #%{public}llu",
                log: log,
                type: .info,
                engineFrameIndex
            )
        }

        ensureSkyline()
        let now = CACurrentMediaTime()
        let dt = max(0.0, now - lastFrameTime)
        lastFrameTime = now

        updateFPS(dt: dt)
        sampleCPU(dt: dt)

        var clearAll = false
        var baseSprites: [SpriteInstance] = []
        var satellitesSprites: [SpriteInstance] = []
        var shootingSprites: [SpriteInstance] = []

        if let skyline = skyline,
            let skylineRenderer = skylineRenderer
        {
            if skyline.shouldClearNow() {
                os_log(
                    "advanceFrameGPU: skyline requested clear — resetting state",
                    log: log,
                    type: .info
                )
                skylineRenderer.resetFrameCounter()
                satellitesRenderer?.reset()
                shootingStarsRenderer?.reset()
                self.skyline = nil
                self.skylineRenderer = nil
                self.shootingStarsRenderer = nil
                self.satellitesRenderer = nil
                clearAll = true
                ensureSkyline()
            }

            baseSprites = skylineRenderer.generateSprites(dtSeconds: dt)
            if config.debugDropBaseEveryNFrames > 0
                && (engineFrameIndex % UInt64(config.debugDropBaseEveryNFrames)
                    == 0)
            {
                if allowFrameLogging {
                    os_log(
                        "advanceFrameGPU: DIAG dropping baseSprites this frame (N=%{public}d)",
                        log: log,
                        type: .info,
                        config.debugDropBaseEveryNFrames
                    )
                }
                baseSprites.removeAll()
            }

            if config.satellitesEnabled, let sat = satellitesRenderer {
                let (sprites, _) = sat.update(dt: dt)
                satellitesSprites = sprites
            } else {
                satellitesSprites.removeAll()
            }

            if config.shootingStarsEnabled, let ss = shootingStarsRenderer {
                let (sprites, _) = ss.update(dt: dt)
                shootingSprites = sprites
            } else {
                shootingSprites.removeAll()
            }
        } else {
            clearAll = true
        }

        if forceClearOnNextFrame {
            os_log(
                "advanceFrameGPU: forceClearOnNextFrame active — will clear accumulation textures",
                log: log,
                type: .info
            )
            clearAll = true
            forceClearOnNextFrame = false
        }

        var moonParams: MoonParams?
        if let moon = skyline?.getMoon() {
            let c = moon.currentCenter()
            let centerPx = SIMD2<Float>(Float(c.x), Float(c.y))
            let r = Float(moon.radius)
            let f = Float(moon.illuminatedFraction)  // illuminated fraction
            let waxSign: Float = moon.waxing ? 1.0 : -1.0
            moonParams = MoonParams(
                centerPx: centerPx,
                radiusPx: r,
                phaseFraction: f,
                brightBrightness: Float(config.moonBrightBrightness),
                darkBrightness: Float(config.moonDarkBrightness),
                waxingSign: waxSign
            )
        }

        if logThisFrame {
            os_log(
                "advanceFrameGPU: sprites base=%{public}d sat=%{public}d shoot=%{public}d moon=%{public}@ clearAll=%{public}@ dt=%.4f starsEff=%.2f/s lightsEff=%.2f/s fractions(star=%.4f light=%.4f)",
                log: log,
                type: .info,
                baseSprites.count,
                satellitesSprites.count,
                shootingSprites.count,
                moonParams != nil ? "yes" : "no",
                clearAll ? "yes" : "no",
                dt,
                effectiveStarsPerSecond(),
                effectiveBuildingLightsPerSecond(),
                config.starSpawnPerSecFractionOfMax,
                config.buildingLightsSpawnPerSecFractionOfMax
            )
        }

        let drawData = StarryDrawData(
            size: size,
            clearAll: clearAll,
            baseSprites: baseSprites,
            satellitesSprites: satellitesSprites,
            shootingSprites: shootingSprites,
            moon: moonParams,
            moonAlbedoImage: moonAlbedoDirty ? moonAlbedoImage : nil,
            showLightAreaTextureFillMask: config.showLightAreaTextureFillMask,
            debugOverlayEnabled: config.debugOverlayEnabled,
            debugFPS: Float(currentFPS),
            debugCPUPercent: Float(currentCPUPercent)
        )
        if moonAlbedoDirty && logThisFrame {
            os_log(
                "advanceFrameGPU: moon albedo image attached for upload",
                log: log,
                type: .info
            )
        }
        moonAlbedoDirty = false
        return drawData
    }

    @discardableResult
    func advanceFrame() -> CGImage? {  // Headless path
        engineFrameIndex &+= 1

        if config.debugOverlayEnabled && config.debugForceClearEveryNFrames > 0
            && (engineFrameIndex % UInt64(config.debugForceClearEveryNFrames)
                == 0)
        {
            forceClearOnNextFrame = true
            os_log(
                "advanceFrame(headless): DIAG force clear scheduled for this frame (every N=%{public}d)",
                log: log,
                type: .info,
                config.debugForceClearEveryNFrames
            )
        }

        let allowFrameLogging = shouldEmitFrameLogs()
        let periodicLogThisFrame =
            allowFrameLogging && (engineLogEveryNFrames > 0)
            && (engineFrameIndex % UInt64(engineLogEveryNFrames) == 0)
        let logThisFrame =
            allowFrameLogging
            && (config.debugLogEveryFrame
                || (verboseLogging && periodicLogThisFrame))
        if logThisFrame {
            os_log(
                "advanceFrame(headless): begin frame #%{public}llu",
                log: log,
                type: .info,
                engineFrameIndex
            )
        }

        ensureSkyline()
        let now = CACurrentMediaTime()
        let dt = max(0.0, now - lastFrameTime)
        lastFrameTime = now

        updateFPS(dt: dt)
        sampleCPU(dt: dt)

        var clearAll = false
        var baseSprites: [SpriteInstance] = []
        var satellitesSprites: [SpriteInstance] = []
        var shootingSprites: [SpriteInstance] = []

        if let skyline = skyline,
            let skylineRenderer = skylineRenderer
        {
            if skyline.shouldClearNow() {
                os_log(
                    "advanceFrame(headless): skyline requested clear — resetting state",
                    log: log,
                    type: .info
                )
                skylineRenderer.resetFrameCounter()
                satellitesRenderer?.reset()
                shootingStarsRenderer?.reset()
                self.skyline = nil
                self.skylineRenderer = nil
                self.shootingStarsRenderer = nil
                self.satellitesRenderer = nil
                clearAll = true
                ensureSkyline()
            }

            baseSprites = skylineRenderer.generateSprites(dtSeconds: dt)
            if config.debugDropBaseEveryNFrames > 0
                && (engineFrameIndex % UInt64(config.debugDropBaseEveryNFrames)
                    == 0)
            {
                if allowFrameLogging {
                    os_log(
                        "advanceFrame(headless): DIAG dropping baseSprites this frame (N=%{public}d)",
                        log: log,
                        type: .info,
                        config.debugDropBaseEveryNFrames
                    )
                }
                baseSprites.removeAll()
            }

            if config.satellitesEnabled, let sat = satellitesRenderer {
                let (spr, _) = sat.update(dt: dt)
                satellitesSprites = spr
            }
            if config.shootingStarsEnabled, let ss = shootingStarsRenderer {
                let (spr, _) = ss.update(dt: dt)
                shootingSprites = spr
            }
        } else {
            clearAll = true
        }

        if forceClearOnNextFrame {
            os_log(
                "advanceFrame(headless): forceClearOnNextFrame active — will clear accumulation textures",
                log: log,
                type: .info
            )
            clearAll = true
            forceClearOnNextFrame = false
        }

        var moonParams: MoonParams?
        if let moon = skyline?.getMoon() {
            let c = moon.currentCenter()
            let centerPx = SIMD2<Float>(Float(c.x), Float(c.y))
            let r = Float(moon.radius)
            let f = Float(moon.illuminatedFraction)
            let waxSign: Float = moon.waxing ? 1.0 : -1.0
            moonParams = MoonParams(
                centerPx: centerPx,
                radiusPx: r,
                phaseFraction: f,
                brightBrightness: Float(config.moonBrightBrightness),
                darkBrightness: Float(config.moonDarkBrightness),
                waxingSign: waxSign
            )
        }

        if logThisFrame {
            os_log(
                "advanceFrame(headless): sprites base=%{public}d sat=%{public}d shoot=%{public}d moon=%{public}@ clearAll=%{public}@ dt=%.4f starsEff=%.2f/s lightsEff=%.2f/s fractions(star=%.4f light=%.4f)",
                log: log,
                type: .info,
                baseSprites.count,
                satellitesSprites.count,
                shootingSprites.count,
                moonParams != nil ? "yes" : "no",
                clearAll ? "yes" : "no",
                dt,
                effectiveStarsPerSecond(),
                effectiveBuildingLightsPerSecond(),
                config.starSpawnPerSecFractionOfMax,
                config.buildingLightsSpawnPerSecFractionOfMax
            )
        }

        let drawData = StarryDrawData(
            size: size,
            clearAll: clearAll,
            baseSprites: baseSprites,
            satellitesSprites: satellitesSprites,
            shootingSprites: shootingSprites,
            moon: moonParams,
            moonAlbedoImage: moonAlbedoDirty ? moonAlbedoImage : nil,
            showLightAreaTextureFillMask: config.showLightAreaTextureFillMask,
            debugOverlayEnabled: config.debugOverlayEnabled,
            debugFPS: Float(currentFPS),
            debugCPUPercent: Float(currentCPUPercent)
        )
        if moonAlbedoDirty && logThisFrame {
            os_log(
                "advanceFrame(headless): moon albedo image attached for upload",
                log: log,
                type: .info
            )
        }
        moonAlbedoDirty = false

        if previewMetalRenderer == nil {
            os_log(
                "Creating headless StarryMetalRenderer",
                log: log,
                type: .info
            )
            previewMetalRenderer = StarryMetalRenderer(log: log)
        }
        guard let renderer = previewMetalRenderer else {
            os_log(
                "Headless render failed: previewMetalRenderer is nil",
                log: log,
                type: .error
            )
            return nil
        }
        renderer.updateDrawableSize(size: size, scale: 1.0)
        let img = renderer.renderToImage(drawData: drawData)
        if img == nil {
            os_log(
                "Headless renderer returned nil CGImage",
                log: log,
                type: .error
            )
        } else if logThisFrame {
            os_log("Headless renderer returned CGImage", log: log, type: .info)
        }
        return img
    }

    func debugSetCompositeBaseOnly(_ enabled: Bool) {
        StarryMetalRenderer.postCompositeMode(enabled ? .baseOnly : .normal)
        previewMetalRenderer?.setCompositeBaseOnlyForDebug(enabled)
        os_log(
            "Debug: set composite BASE-ONLY = %{public}@",
            log: log,
            type: .info,
            enabled ? "true" : "false"
        )
    }

    func debugSetCompositeSatellitesOnly(_ enabled: Bool) {
        StarryMetalRenderer.postCompositeMode(
            enabled ? .satellitesOnly : .normal
        )
        previewMetalRenderer?.setCompositeSatellitesOnlyForDebug(enabled)
        os_log(
            "Debug: set composite SATELLITES-ONLY = %{public}@",
            log: log,
            type: .info,
            enabled ? "true" : "false"
        )
    }

    private func sampleCPU(dt: CFTimeInterval) {
        guard dt > 0 else { return }
        var info = task_thread_times_info_data_t()
        var infoCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let kerr = withUnsafeMutablePointer(to: &info) {
            infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(infoCount)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_THREAD_TIMES_INFO),
                    $0,
                    &infoCount
                )
            }
        }

        var cpuSeconds: Double = 0
        if kerr == KERN_SUCCESS {
            let user =
                Double(info.user_time.seconds) + Double(
                    info.user_time.microseconds
                ) / 1_000_000.0
            let system =
                Double(info.system_time.seconds) + Double(
                    info.system_time.microseconds
                ) / 1_000_000.0
            cpuSeconds = user + system
        } else {
            return
        }

        if lastProcessCPUTimesSeconds == 0 {
            lastProcessCPUTimesSeconds = cpuSeconds
            lastCPUSampleWallTime = CACurrentMediaTime()
            return
        }
        let deltaCPU = max(0, cpuSeconds - lastProcessCPUTimesSeconds)
        let percent = (deltaCPU / dt) * 100.0
        currentCPUPercent = currentCPUPercent * 0.8 + percent * 0.2
        lastProcessCPUTimesSeconds = cpuSeconds
        lastCPUSampleWallTime = CACurrentMediaTime()
    }

    private func updateFPS(dt: CFTimeInterval) {
        fpsFrameCount += 1
        fpsAccumulatedTime += dt
        if fpsAccumulatedTime >= 0.5 {
            let fps = Double(fpsFrameCount) / fpsAccumulatedTime
            currentFPS = currentFPS * 0.6 + fps * 0.4
            fpsAccumulatedTime = 0
            fpsFrameCount = 0
            if config.debugOverlayEnabled {
                os_log(
                    "Stats: FPS=%.1f CPU=%.1f%%",
                    log: log,
                    type: .debug,
                    currentFPS,
                    currentCPUPercent
                )
            }
        }
    }

    private func value<T>(_ key: String, from userInfo: [AnyHashable: Any]?)
        -> T?
    {
        guard let ui = userInfo, let raw = ui[key] else { return nil }
        if let v = raw as? T { return v }
        if T.self == Bool.self {
            if let n = raw as? NSNumber { return (n.boolValue as! T) }
            if let s = raw as? String {
                let lowered = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let truthy: Set<String> = ["1", "true", "yes", "on", "y"]
                let falsy: Set<String> = ["0", "false", "no", "off", "n"]
                if truthy.contains(lowered) { return (true as! T) }
                if falsy.contains(lowered) { return (false as! T) }
            }
        } else if T.self == Int.self {
            if let n = raw as? NSNumber { return (n.intValue as! T) }
            if let s = raw as? String,
                let iv = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return (iv as! T)
            }
        } else if T.self == Double.self {
            if let n = raw as? NSNumber { return (n.doubleValue as! T) }
            if let s = raw as? String,
                let dv = Double(
                    s.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            {
                return (dv as! T)
            }
        }
        return nil
    }
}
