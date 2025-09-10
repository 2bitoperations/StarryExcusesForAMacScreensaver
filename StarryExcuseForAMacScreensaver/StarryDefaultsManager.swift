//
//  StarryConfigSheetManager.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 5/2/19.
//

import Foundation
import ScreenSaver
import os

class StarryDefaultsManager {
    var defaults: UserDefaults
    
    // Default fallback constants (single source of truth)
    private let defaultStarsPerUpdate = 80                // legacy
    private let defaultStarsPerSecond = 800.0             // new authoritative (≈ 80 * 10fps legacy assumption)
    // Legacy per-update building lights (used to derive per-second if not explicitly set)
    private let defaultBuildingLightsPerUpdate = 15
    // Target visual density originally: 15 / update @ 10 FPS => 150 lights / second
    private let defaultBuildingLightsPerSecond = 150.0
    
    private let defaultBuildingHeight = 0.35
    private let defaultSecsBetweenClears = 120.0
    private let defaultMoonTraversalMinutes = 60
    private let defaultBuildingFrequency = 0.033
    // New unified moon size setting (% of screen width) ~80px on 3000px screen.
    private let defaultMoonDiameterScreenWidthPercent = 80.0 / 3000.0
    private let defaultMoonBrightBrightness = 1.0
    private let defaultMoonDarkBrightness = 0.15
    private let defaultMoonPhaseOverrideEnabled = false
    // 0 = New, 0.25 ≈ First Quarter, 0.5 = Full, 0.75 ≈ Last Quarter, 1.0 = New
    private let defaultMoonPhaseOverrideValue = 0.0
    // Debug toggle defaults
    private let defaultShowLightAreaTextureFillMask = false
    private let defaultDebugOverlayEnabled = false
    
    // Shooting Stars defaults
    private let defaultShootingStarsEnabled = true
    private let defaultShootingStarsAvgSeconds = 7.0
    // Direction mode raw mapping:
    // 0 Random, 1 LtoR, 2 RtoL, 3 TL->BR, 4 TR->BL
    private let defaultShootingStarsDirectionMode = 0
    private let defaultShootingStarsLength: Double = 160
    private let defaultShootingStarsSpeed: Double = 600
    private let defaultShootingStarsThickness: Double = 2
    private let defaultShootingStarsBrightness: Double = 0.9
    // NEW: shooting star trail half-life seconds (0.01 .. 2.0)
    private let defaultShootingStarsTrailHalfLifeSeconds: Double = 0.18
    private let defaultShootingStarsDebugSpawnBounds = false
    
    // Satellites defaults
    private let defaultSatellitesEnabled = true
    private let defaultSatellitesAvgSpawnSeconds = 0.75     // frequent
    private let defaultSatellitesSpeed = 90.0               // px/sec
    private let defaultSatellitesSize = 2.0                 // px
    private let defaultSatellitesBrightness = 0.9           // 0..1
    private let defaultSatellitesTrailing = true
    // NEW: satellites trail half-life seconds (0.01 .. 2.0)
    private let defaultSatellitesTrailHalfLifeSeconds = 0.18
    
    init() {
        let identifier = Bundle(for: StarryDefaultsManager.self).bundleIdentifier
        defaults = ScreenSaverDefaults.init(forModuleWithName: identifier!)!
        migrateLegacyKeysIfNeeded()
    }
    
    // MARK: - Migration
    
    private func migrateLegacyKeysIfNeeded() {
        // Legacy key: ShowCrescentClipMask -> ShowLightAreaTextureFillMask
        if defaults.object(forKey: "ShowLightAreaTextureFillMask") == nil,
           defaults.object(forKey: "ShowCrescentClipMask") != nil {
            let legacy = defaults.bool(forKey: "ShowCrescentClipMask")
            defaults.set(legacy, forKey: "ShowLightAreaTextureFillMask")
            defaults.removeObject(forKey: "ShowCrescentClipMask")
            defaults.synchronize()
        }
        // Remove deprecated oversize keys if present
        if defaults.object(forKey: "DarkMinorityOversizeOverrideEnabled") != nil {
            defaults.removeObject(forKey: "DarkMinorityOversizeOverrideEnabled")
        }
        if defaults.object(forKey: "DarkMinorityOversizeOverrideValue") != nil {
            defaults.removeObject(forKey: "DarkMinorityOversizeOverrideValue")
        }
        // Remove old per-pixel moon size keys (now superseded by percent).
        if defaults.object(forKey: "MoonMinRadius") != nil {
            defaults.removeObject(forKey: "MoonMinRadius")
        }
        if defaults.object(forKey: "MoonMaxRadius") != nil {
            defaults.removeObject(forKey: "MoonMaxRadius")
        }
        
        // MIGRATION: Shooting stars legacy factor (per-frame keep 0.85..0.99) -> half-life seconds.
        if defaults.object(forKey: "ShootingStarsTrailHalfLifeSeconds") == nil {
            if let _ = defaults.object(forKey: "ShootingStarsTrailDecay") {
                let factor = defaults.double(forKey: "ShootingStarsTrailDecay")
                let fps = 60.0
                let f = max(0.0001, min(0.9999, factor))
                let hl = max(0.01, min(2.0, log(0.5) / (fps * log(f))))
                defaults.set(hl, forKey: "ShootingStarsTrailHalfLifeSeconds")
            } else {
                defaults.set(defaultShootingStarsTrailHalfLifeSeconds, forKey: "ShootingStarsTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        } else {
            let hl = defaults.double(forKey: "ShootingStarsTrailHalfLifeSeconds")
            let clamped = max(0.01, min(2.0, hl))
            if clamped != hl {
                defaults.set(clamped, forKey: "ShootingStarsTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        }
        
        // MIGRATION: Satellites legacy conversions -> half-life
        if defaults.object(forKey: "SatellitesTrailHalfLifeSeconds") == nil {
            if let _ = defaults.object(forKey: "SatellitesTrailDecay") {
                let v = defaults.double(forKey: "SatellitesTrailDecay")
                var hl: Double
                if v > 0.0 && v <= 1.0 {
                    let fps = 60.0
                    let f = max(0.0001, min(0.9999, v))
                    hl = max(0.01, min(2.0, log(0.5) / (fps * log(f))))
                } else {
                    let t = max(0.01, min(120.0, v))
                    hl = t * log(2.0) / log(100.0)
                    hl = max(0.01, min(2.0, hl))
                }
                defaults.set(hl, forKey: "SatellitesTrailHalfLifeSeconds")
            } else {
                defaults.set(defaultSatellitesTrailHalfLifeSeconds, forKey: "SatellitesTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        } else {
            let hl = defaults.double(forKey: "SatellitesTrailHalfLifeSeconds")
            let clamped = max(0.01, min(2.0, hl))
            if clamped != hl {
                defaults.set(clamped, forKey: "SatellitesTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        }
        
        // MIGRATION (2025): introduce StarsPerSecond (authoritative)
        if defaults.object(forKey: "StarsPerSecond") == nil {
            if defaults.object(forKey: "StarsPerUpdate") != nil {
                let legacy = max(0, defaults.integer(forKey: "StarsPerUpdate"))
                // Legacy assumed 10 FPS
                defaults.set(Double(legacy) * 10.0, forKey: "StarsPerSecond")
            } else {
                defaults.set(defaultStarsPerSecond, forKey: "StarsPerSecond")
            }
            defaults.synchronize()
        }
        
        // NEW (2025): building lights per second (already handled previously)
        if defaults.object(forKey: "BuildingLightsPerSecond") == nil {
            if defaults.object(forKey: "BuildingLightsPerUpdate") != nil {
                let legacy = max(0, defaults.integer(forKey: "BuildingLightsPerUpdate"))
                defaults.set(Double(legacy) * 10.0, forKey: "BuildingLightsPerSecond")
            } else {
                defaults.set(defaultBuildingLightsPerSecond, forKey: "BuildingLightsPerSecond")
            }
            defaults.synchronize()
        }
    }
    
    // MARK: - Stored properties (with range enforcement)
    
    // NEW authoritative stars-per-second configuration.
    var starsPerSecond: Double {
        set {
            let clamped = max(0.0, newValue)
            defaults.set(clamped, forKey: "StarsPerSecond")
            // Keep legacy key loosely synchronized (divide by assumed 10 FPS) for any old code still reading it.
            defaults.set(Int(round(clamped / 10.0)), forKey: "StarsPerUpdate")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "StarsPerSecond") == nil {
                // Derive a default if migration somehow failed
                if defaults.object(forKey: "StarsPerUpdate") != nil {
                    let legacy = max(0, defaults.integer(forKey: "StarsPerUpdate"))
                    return Double(legacy) * 10.0
                }
                return defaultStarsPerSecond
            }
            let v = defaults.double(forKey: "StarsPerSecond")
            return v >= 0 ? v : defaultStarsPerSecond
        }
    }
    
    // LEGACY (deprecated): stars per update. Derived from starsPerSecond / assumed 10 FPS.
    // Retained for backward compatibility with older runtime components.
    var starsPerUpdate: Int {
        set {
            let val = max(0, newValue)
            defaults.set(val, forKey: "StarsPerUpdate")
            // Keep new key aligned (multiply by 10 legacy FPS assumption) only if user has not explicitly
            // set StarsPerSecond separately; we overwrite anyway for simplicity.
            defaults.set(Double(val) * 10.0, forKey: "StarsPerSecond")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "StarsPerUpdate") == nil {
                // Derive from starsPerSecond
                return Int(max(0, round(starsPerSecond / 10.0)))
            }
            let v = defaults.integer(forKey: "StarsPerUpdate")
            return v > 0 ? v : Int(max(0, round(starsPerSecond / 10.0)))
        }
    }
    
    // Legacy: building lights per update (kept for backward compatibility / conversion)
    var buildingLightsPerUpdate: Int {
        set { defaults.set(newValue, forKey: "BuildingLightsPerUpdate"); defaults.synchronize() }
        get {
            if defaults.object(forKey: "BuildingLightsPerUpdate") == nil {
                return defaultBuildingLightsPerUpdate
            }
            let v = defaults.integer(forKey: "BuildingLightsPerUpdate")
            return v > 0 ? v : defaultBuildingLightsPerUpdate
        }
    }
    
    // Preferred new setting: building lights per second (time-based spawning).
    var buildingLightsPerSecond: Double {
        set {
            let clamped = max(0.0, newValue)
            defaults.set(clamped, forKey: "BuildingLightsPerSecond")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "BuildingLightsPerSecond") == nil {
                return Double(buildingLightsPerUpdate) * 10.0
            }
            let v = defaults.double(forKey: "BuildingLightsPerSecond")
            return v > 0 ? v : defaultBuildingLightsPerSecond
        }
    }
    
    var buildingHeight: Double {
        set { defaults.set(newValue, forKey: "BuildingHeight"); defaults.synchronize() }
        get {
            let v = defaults.double(forKey: "BuildingHeight")
            return (v > 0 && v < 1) ? v : defaultBuildingHeight
        }
    }
    
    var secsBetweenClears: Double {
        set { defaults.set(newValue, forKey: "SecsBetweenClears"); defaults.synchronize() }
        get {
            let v = defaults.double(forKey: "SecsBetweenClears")
            return v > 0 ? v : defaultSecsBetweenClears
        }
    }
    
    // Moon traversal duration (minutes). 1 .. 720 (12h).
    var moonTraversalMinutes: Int {
        set {
            let clamped = max(1, min(720, newValue))
            defaults.set(clamped, forKey: "MoonTraversalMinutes")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "MoonTraversalMinutes")
            return (1...720).contains(v) ? v : defaultMoonTraversalMinutes
        }
    }
    
    // Building frequency
    var buildingFrequency: Double {
        set {
            let clamped = max(0.001, min(1.0, newValue))
            defaults.set(clamped, forKey: "BuildingFrequency")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "BuildingFrequency")
            if v.isNaN || v <= 0 { return defaultBuildingFrequency }
            return v
        }
    }
    
    // Unified moon size: diameter as % of screen width.
    var moonDiameterScreenWidthPercent: Double {
        set {
            let clamped = max(0.001, min(0.25, newValue))
            defaults.set(clamped, forKey: "MoonDiameterScreenWidthPercent")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonDiameterScreenWidthPercent")
            if v.isNaN || v < 0.001 || v > 0.25 {
                return defaultMoonDiameterScreenWidthPercent
            }
            return v
        }
    }
    
    var moonBrightBrightness: Double {
        set {
            let clamped = max(0.2, min(1.2, newValue))
            defaults.set(clamped, forKey: "MoonBrightBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonBrightBrightness")
            return (v >= 0.2 && v <= 1.2) ? v : defaultMoonBrightBrightness
        }
    }
    
    var moonDarkBrightness: Double {
        set {
            let clamped = max(0.0, min(0.9, newValue))
            defaults.set(clamped, forKey: "MoonDarkBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonDarkBrightness")
            return (v >= 0.0 && v <= 0.9) ? v : defaultMoonDarkBrightness
        }
    }
    
    var moonPhaseOverrideEnabled: Bool {
        set {
            defaults.set(newValue, forKey: "MoonPhaseOverrideEnabled")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "MoonPhaseOverrideEnabled") == nil {
                return defaultMoonPhaseOverrideEnabled
            }
            return defaults.bool(forKey: "MoonPhaseOverrideEnabled")
        }
    }
    
    var moonPhaseOverrideValue: Double {
        set {
            let clamped = max(0.0, min(1.0, newValue))
            defaults.set(clamped, forKey: "MoonPhaseOverrideValue")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonPhaseOverrideValue")
            if v.isNaN || v < 0.0 || v > 1.0 {
                return defaultMoonPhaseOverrideValue
            }
            return v
        }
    }
    
    var showLightAreaTextureFillMask: Bool {
        set {
            defaults.set(newValue, forKey: "ShowLightAreaTextureFillMask")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "ShowLightAreaTextureFillMask") == nil {
                return defaultShowLightAreaTextureFillMask
            }
            return defaults.bool(forKey: "ShowLightAreaTextureFillMask")
        }
    }
    
    var debugOverlayEnabled: Bool {
        set {
            defaults.set(newValue, forKey: "DebugOverlayEnabled")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "DebugOverlayEnabled") == nil {
                return defaultDebugOverlayEnabled
            }
            return defaults.bool(forKey: "DebugOverlayEnabled")
        }
    }
    
    // MARK: - Shooting Stars Settings
    
    var shootingStarsEnabled: Bool {
        set { defaults.set(newValue, forKey: "ShootingStarsEnabled"); defaults.synchronize() }
        get {
            if defaults.object(forKey: "ShootingStarsEnabled") == nil {
                return defaultShootingStarsEnabled
            }
            return defaults.bool(forKey: "ShootingStarsEnabled")
        }
    }
    
    var shootingStarsAvgSeconds: Double {
        set {
            let clamped = max(0.5, min(600.0, newValue))
            defaults.set(clamped, forKey: "ShootingStarsAvgSeconds")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsAvgSeconds")
            return (v >= 0.5 && v <= 600) ? v : defaultShootingStarsAvgSeconds
        }
    }
    
    var shootingStarsDirectionMode: Int {
        set {
            let clamped = max(0, min(4, newValue))
            defaults.set(clamped, forKey: "ShootingStarsDirectionMode")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "ShootingStarsDirectionMode")
            return (0...4).contains(v) ? v : defaultShootingStarsDirectionMode
        }
    }
    
    var shootingStarsLength: Double {
        set {
            let clamped = max(40, min(300, newValue))
            defaults.set(clamped, forKey: "ShootingStarsLength")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsLength")
            return (v >= 40 && v <= 300) ? v : defaultShootingStarsLength
        }
    }
    
    var shootingStarsSpeed: Double {
        set {
            let clamped = max(200, min(1200, newValue))
            defaults.set(clamped, forKey: "ShootingStarsSpeed")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsSpeed")
            return (v >= 200 && v <= 1200) ? v : defaultShootingStarsSpeed
        }
    }
    
    var shootingStarsThickness: Double {
        set {
            let clamped = max(1, min(4, newValue))
            defaults.set(clamped, forKey: "ShootingStarsThickness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsThickness")
            return (v >= 1 && v <= 4) ? v : defaultShootingStarsThickness
        }
    }
    
    var shootingStarsBrightness: Double {
        set {
            let clamped = max(0.3, min(1.0, newValue))
            defaults.set(clamped, forKey: "ShootingStarsBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsBrightness")
            return (v >= 0.3 && v <= 1.0) ? v : defaultShootingStarsBrightness
        }
    }
    
    var shootingStarsTrailHalfLifeSeconds: Double {
        set {
            let clamped = max(0.01, min(2.0, newValue))
            defaults.set(clamped, forKey: "ShootingStarsTrailHalfLifeSeconds")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "ShootingStarsTrailHalfLifeSeconds") == nil {
                return defaultShootingStarsTrailHalfLifeSeconds
            }
            let v = defaults.double(forKey: "ShootingStarsTrailHalfLifeSeconds")
            return max(0.01, min(2.0, v))
        }
    }
    
    var shootingStarsDebugShowSpawnBounds: Bool {
        set {
            defaults.set(newValue, forKey: "ShootingStarsDebugShowSpawnBounds")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "ShootingStarsDebugShowSpawnBounds") == nil {
                return defaultShootingStarsDebugSpawnBounds
            }
            return defaults.bool(forKey: "ShootingStarsDebugShowSpawnBounds")
        }
    }
    
    // MARK: - Satellites Settings
    
    var satellitesEnabled: Bool {
        set { defaults.set(newValue, forKey: "SatellitesEnabled"); defaults.synchronize() }
        get {
            if defaults.object(forKey: "SatellitesEnabled") == nil {
                return defaultSatellitesEnabled
            }
            return defaults.bool(forKey: "SatellitesEnabled")
        }
    }
    
    var satellitesAvgSpawnSeconds: Double {
        set {
            let clamped = max(0.2, min(120.0, newValue))
            defaults.set(clamped, forKey: "SatellitesAvgSpawnSeconds")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesAvgSpawnSeconds")
            if v.isNaN || v < 0.2 || v > 120.0 {
                return defaultSatellitesAvgSpawnSeconds
            }
            return v
        }
    }
    
    var satellitesSpeed: Double {
        set {
            let clamped = max(10.0, min(600.0, newValue))
            defaults.set(clamped, forKey: "SatellitesSpeed")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesSpeed")
            return (v >= 10.0 && v <= 600.0) ? v : defaultSatellitesSpeed
        }
    }
    
    var satellitesSize: Double {
        set {
            let clamped = max(1.0, min(6.0, newValue))
            defaults.set(clamped, forKey: "SatellitesSize")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesSize")
            return (v >= 1.0 && v <= 6.0) ? v : defaultSatellitesSize
        }
    }
    
    var satellitesBrightness: Double {
        set {
            let clamped = max(0.2, min(1.2, newValue))
            defaults.set(clamped, forKey: "SatellitesBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesBrightness")
            return (v >= 0.2 && v <= 1.2) ? v : defaultSatellitesBrightness
        }
    }
    
    var satellitesTrailing: Bool {
        set { defaults.set(newValue, forKey: "SatellitesTrailing"); defaults.synchronize() }
        get {
            if defaults.object(forKey: "SatellitesTrailing") == nil {
                return defaultSatellitesTrailing
            }
            return defaults.bool(forKey: "SatellitesTrailing")
        }
    }
    
    var satellitesTrailHalfLifeSeconds: Double {
        set {
            let clamped = max(0.01, min(2.0, newValue))
            defaults.set(clamped, forKey: "SatellitesTrailHalfLifeSeconds")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "SatellitesTrailHalfLifeSeconds") == nil {
                return defaultSatellitesTrailHalfLifeSeconds
            }
            let v = defaults.double(forKey: "SatellitesTrailHalfLifeSeconds")
            return max(0.01, min(2.0, v))
        }
    }
    
    // MARK: - Runtime validation (screensaver start-time)
    func validateAndCorrectMoonSettings(log: OSLog) {
        var corrected = false
        
        if moonBrightBrightness < moonDarkBrightness {
            os_log("Invalid moon brightness settings (bright %.3f < dark %.3f). Reverting to defaults (bright %.2f, dark %.2f).",
                   log: log, type: .error,
                   moonBrightBrightness, moonDarkBrightness,
                   defaultMoonBrightBrightness, defaultMoonDarkBrightness)
            defaults.set(defaultMoonBrightBrightness, forKey: "MoonBrightBrightness")
            defaults.set(defaultMoonDarkBrightness, forKey: "MoonDarkBrightness")
            corrected = true
        }
        
        let phaseOverride = defaults.double(forKey: "MoonPhaseOverrideValue")
        if phaseOverride.isNaN || phaseOverride < 0.0 || phaseOverride > 1.0 {
            os_log("Out-of-range MoonPhaseOverrideValue %.3f detected. Resetting to %.3f.",
                   log: log, type: .error, phaseOverride, defaultMoonPhaseOverrideValue)
            defaults.set(defaultMoonPhaseOverrideValue, forKey: "MoonPhaseOverrideValue")
            corrected = true
        }
        
        let percent = defaults.double(forKey: "MoonDiameterScreenWidthPercent")
        if percent.isNaN || percent < 0.001 || percent > 0.25 {
            os_log("Out-of-range MoonDiameterScreenWidthPercent %.5f detected. Resetting to default %.5f.",
                   log: log, type: .error, percent, defaultMoonDiameterScreenWidthPercent)
            defaults.set(defaultMoonDiameterScreenWidthPercent, forKey: "MoonDiameterScreenWidthPercent")
            corrected = true
        }
        
        if corrected { defaults.synchronize() }
    }
}
