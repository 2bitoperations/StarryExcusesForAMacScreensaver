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
    
    // MARK: - Public range constants (single source of truth for UI components)
    // Stars / Building Lights
    static let starsPerSecondMin: Double = 0.0
    static let buildingLightsPerSecondMin: Double = 0.0
    
    // Clears
    static let secsBetweenClearsMin: Double = 1.0
    
    // Building geometry / spawning
    static let buildingHeightMin: Double = 0.0
    static let buildingHeightMax: Double = 1.0
    static let buildingFrequencyMin: Double = 0.001
    static let buildingFrequencyMax: Double = 1.0
    
    // Moon
    static let moonDiameterPercentMin: Double = 0.001
    static let moonDiameterPercentMax: Double = 0.25
    static let moonBrightBrightnessMin: Double = 0.2
    static let moonBrightBrightnessMax: Double = 1.2
    static let moonDarkBrightnessMin: Double = 0.0
    static let moonDarkBrightnessMax: Double = 0.9
    static let moonPhaseValueMin: Double = 0.0
    static let moonPhaseValueMax: Double = 1.0
    static let moonTraversalMinutesMin: Int = 1
    static let moonTraversalMinutesMax: Int = 720
    
    // Shooting Stars
    static let shootingStarsAvgSecondsMin: Double = 0.5
    static let shootingStarsAvgSecondsMax: Double = 600.0
    static let shootingStarsLengthMin: Double = 40.0
    static let shootingStarsLengthMax: Double = 300.0
    static let shootingStarsSpeedMin: Double = 200.0
    static let shootingStarsSpeedMax: Double = 1200.0
    static let shootingStarsThicknessMin: Double = 1.0
    static let shootingStarsThicknessMax: Double = 4.0
    static let shootingStarsBrightnessMin: Double = 0.0
    static let shootingStarsBrightnessMax: Double = 1.0
    static let shootingStarsTrailHalfLifeMin: Double = 0.01
    static let shootingStarsTrailHalfLifeMax: Double = 2.0
    static let shootingStarsDirectionModeMin: Int = 0
    static let shootingStarsDirectionModeMax: Int = 4
    
    // Satellites
    static let satellitesAvgSpawnSecondsMin: Double = 0.2
    static let satellitesAvgSpawnSecondsMax: Double = 120.0
    static let satellitesSpeedMin: Double = 1.0
    static let satellitesSpeedMax: Double = 100.0
    static let satellitesSizeMin: Double = 1.0
    static let satellitesSizeMax: Double = 6.0
    static let satellitesBrightnessMin: Double = 0.2
    static let satellitesBrightnessMax: Double = 1.2
    static let satellitesTrailHalfLifeMin: Double = 0.0
    static let satellitesTrailHalfLifeMax: Double = 0.5
    
    // Default fallback constants (single source of truth for values)
    private let defaultStarsPerUpdate = 80                // legacy
    private let defaultStarsPerSecond = 800.0             // new authoritative (≈ 80 * 10fps legacy assumption)
    private let defaultBuildingLightsPerUpdate = 15
    private let defaultBuildingLightsPerSecond = 150.0
    
    private let defaultBuildingHeight = 0.35
    private let defaultSecsBetweenClears = 120.0
    private let defaultMoonTraversalMinutes = 60
    private let defaultBuildingFrequency = 0.033
    private let defaultMoonDiameterScreenWidthPercent = 80.0 / 3000.0
    private let defaultMoonBrightBrightness = 1.0
    private let defaultMoonDarkBrightness = 0.15
    private let defaultMoonPhaseOverrideEnabled = false
    private let defaultMoonPhaseOverrideValue = 0.0
    private let defaultShowLightAreaTextureFillMask = false
    private let defaultDebugOverlayEnabled = false
    
    // Shooting Stars defaults
    private let defaultShootingStarsEnabled = true
    private let defaultShootingStarsAvgSeconds = 7.0
    private let defaultShootingStarsDirectionMode = 0
    private let defaultShootingStarsLength: Double = 160
    private let defaultShootingStarsSpeed: Double = 600
    private let defaultShootingStarsThickness: Double = 2
    private let defaultShootingStarsBrightness: Double = 0.2
    private let defaultShootingStarsTrailHalfLifeSeconds: Double = 0.18
    private let defaultShootingStarsDebugSpawnBounds = false
    
    // Satellites defaults
    private let defaultSatellitesEnabled = true
    private let defaultSatellitesAvgSpawnSeconds = 0.75
    private let defaultSatellitesSpeed = 30.0
    private let defaultSatellitesSize = 2.0
    private let defaultSatellitesBrightness = 0.5
    private let defaultSatellitesTrailing = true
    private let defaultSatellitesTrailHalfLifeSeconds = 0.10
    
    init() {
        let identifier = Bundle(for: StarryDefaultsManager.self).bundleIdentifier
        defaults = ScreenSaverDefaults.init(forModuleWithName: identifier!)!
        migrateLegacyKeysIfNeeded()
    }
    
    // MARK: - Migration
    
    private func migrateLegacyKeysIfNeeded() {
        if defaults.object(forKey: "ShowLightAreaTextureFillMask") == nil,
           defaults.object(forKey: "ShowCrescentClipMask") != nil {
            let legacy = defaults.bool(forKey: "ShowCrescentClipMask")
            defaults.set(legacy, forKey: "ShowLightAreaTextureFillMask")
            defaults.removeObject(forKey: "ShowCrescentClipMask")
            defaults.synchronize()
        }
        if defaults.object(forKey: "DarkMinorityOversizeOverrideEnabled") != nil {
            defaults.removeObject(forKey: "DarkMinorityOversizeOverrideEnabled")
        }
        if defaults.object(forKey: "DarkMinorityOversizeOverrideValue") != nil {
            defaults.removeObject(forKey: "DarkMinorityOversizeOverrideValue")
        }
        if defaults.object(forKey: "MoonMinRadius") != nil {
            defaults.removeObject(forKey: "MoonMinRadius")
        }
        if defaults.object(forKey: "MoonMaxRadius") != nil {
            defaults.removeObject(forKey: "MoonMaxRadius")
        }
        
        if defaults.object(forKey: "ShootingStarsTrailHalfLifeSeconds") == nil {
            if let _ = defaults.object(forKey: "ShootingStarsTrailDecay") {
                let factor = defaults.double(forKey: "ShootingStarsTrailDecay")
                let fps = 60.0
                let f = max(0.0001, min(0.9999, factor))
                let hl = max(Self.shootingStarsTrailHalfLifeMin,
                             min(Self.shootingStarsTrailHalfLifeMax,
                                 log(0.5) / (fps * log(f))))
                defaults.set(hl, forKey: "ShootingStarsTrailHalfLifeSeconds")
            } else {
                defaults.set(defaultShootingStarsTrailHalfLifeSeconds, forKey: "ShootingStarsTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        } else {
            let hl = defaults.double(forKey: "ShootingStarsTrailHalfLifeSeconds")
            let clamped = max(Self.shootingStarsTrailHalfLifeMin,
                              min(Self.shootingStarsTrailHalfLifeMax, hl))
            if clamped != hl {
                defaults.set(clamped, forKey: "ShootingStarsTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        }
        
        if defaults.object(forKey: "SatellitesTrailHalfLifeSeconds") == nil {
            if let _ = defaults.object(forKey: "SatellitesTrailDecay") {
                let v = defaults.double(forKey: "SatellitesTrailDecay")
                var hl: Double
                if v > 0.0 && v <= 1.0 {
                    let fps = 60.0
                    let f = max(0.0001, min(0.9999, v))
                    hl = max(Self.shootingStarsTrailHalfLifeMin, min(Self.shootingStarsTrailHalfLifeMax, log(0.5) / (fps * log(f))))
                } else {
                    let t = max(0.01, min(120.0, v))
                    hl = t * log(2.0) / log(100.0)
                    hl = max(Self.shootingStarsTrailHalfLifeMin, min(Self.shootingStarsTrailHalfLifeMax, hl))
                }
                defaults.set(hl, forKey: "SatellitesTrailHalfLifeSeconds")
            } else {
                defaults.set(defaultSatellitesTrailHalfLifeSeconds, forKey: "SatellitesTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        }
        
        let oldHL = defaults.double(forKey: "SatellitesTrailHalfLifeSeconds")
        if oldHL.isNaN || oldHL < Self.satellitesTrailHalfLifeMin || oldHL > Self.satellitesTrailHalfLifeMax {
            let clamped = max(Self.satellitesTrailHalfLifeMin,
                              min(Self.satellitesTrailHalfLifeMax,
                                  oldHL.isNaN ? defaultSatellitesTrailHalfLifeSeconds : oldHL))
            defaults.set(clamped == oldHL ? clamped : (oldHL.isNaN ? defaultSatellitesTrailHalfLifeSeconds : clamped),
                         forKey: "SatellitesTrailHalfLifeSeconds")
            defaults.synchronize()
        }
        
        if defaults.object(forKey: "StarsPerSecond") == nil {
            if defaults.object(forKey: "StarsPerUpdate") != nil {
                let legacy = max(0, defaults.integer(forKey: "StarsPerUpdate"))
                defaults.set(Double(legacy) * 10.0, forKey: "StarsPerSecond")
            } else {
                defaults.set(defaultStarsPerSecond, forKey: "StarsPerSecond")
            }
            defaults.synchronize()
        }
        
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
    
    var starsPerSecond: Double {
        set {
            let clamped = max(Self.starsPerSecondMin, newValue)
            defaults.set(clamped, forKey: "StarsPerSecond")
            defaults.set(Int(round(clamped / 10.0)), forKey: "StarsPerUpdate")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "StarsPerSecond") == nil {
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
    
    var starsPerUpdate: Int {
        set {
            let val = max(0, newValue)
            defaults.set(val, forKey: "StarsPerUpdate")
            defaults.set(Double(val) * 10.0, forKey: "StarsPerSecond")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "StarsPerUpdate") == nil {
                return Int(max(0, round(starsPerSecond / 10.0)))
            }
            let v = defaults.integer(forKey: "StarsPerUpdate")
            return v > 0 ? v : Int(max(0, round(starsPerSecond / 10.0)))
        }
    }
    
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
    
    var buildingLightsPerSecond: Double {
        set {
            let clamped = max(Self.buildingLightsPerSecondMin, newValue)
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
            return (v > Self.buildingHeightMin && v < Self.buildingHeightMax) ? v : defaultBuildingHeight
        }
    }
    
    var secsBetweenClears: Double {
        set { defaults.set(newValue, forKey: "SecsBetweenClears"); defaults.synchronize() }
        get {
            let v = defaults.double(forKey: "SecsBetweenClears")
            return v > Self.secsBetweenClearsMin ? v : defaultSecsBetweenClears
        }
    }
    
    var moonTraversalMinutes: Int {
        set {
            let clamped = max(Self.moonTraversalMinutesMin, min(Self.moonTraversalMinutesMax, newValue))
            defaults.set(clamped, forKey: "MoonTraversalMinutes")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "MoonTraversalMinutes")
            return (Self.moonTraversalMinutesMin...Self.moonTraversalMinutesMax).contains(v) ? v : defaultMoonTraversalMinutes
        }
    }
    
    var buildingFrequency: Double {
        set {
            let clamped = max(Self.buildingFrequencyMin, min(Self.buildingFrequencyMax, newValue))
            defaults.set(clamped, forKey: "BuildingFrequency")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "BuildingFrequency")
            if v.isNaN || v <= 0 { return defaultBuildingFrequency }
            return v
        }
    }
    
    var moonDiameterScreenWidthPercent: Double {
        set {
            let clamped = max(Self.moonDiameterPercentMin, min(Self.moonDiameterPercentMax, newValue))
            defaults.set(clamped, forKey: "MoonDiameterScreenWidthPercent")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonDiameterScreenWidthPercent")
            if v.isNaN || v < Self.moonDiameterPercentMin || v > Self.moonDiameterPercentMax {
                return defaultMoonDiameterScreenWidthPercent
            }
            return v
        }
    }
    
    var moonBrightBrightness: Double {
        set {
            let clamped = max(Self.moonBrightBrightnessMin, min(Self.moonBrightBrightnessMax, newValue))
            defaults.set(clamped, forKey: "MoonBrightBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonBrightBrightness")
            return (v >= Self.moonBrightBrightnessMin && v <= Self.moonBrightBrightnessMax) ? v : defaultMoonBrightBrightness
        }
    }
    
    var moonDarkBrightness: Double {
        set {
            let clamped = max(Self.moonDarkBrightnessMin, min(Self.moonDarkBrightnessMax, newValue))
            defaults.set(clamped, forKey: "MoonDarkBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonDarkBrightness")
            return (v >= Self.moonDarkBrightnessMin && v <= Self.moonDarkBrightnessMax) ? v : defaultMoonDarkBrightness
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
            let clamped = max(Self.moonPhaseValueMin, min(Self.moonPhaseValueMax, newValue))
            defaults.set(clamped, forKey: "MoonPhaseOverrideValue")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonPhaseOverrideValue")
            if v.isNaN || v < Self.moonPhaseValueMin || v > Self.moonPhaseValueMax {
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
            let clamped = max(Self.shootingStarsAvgSecondsMin, min(Self.shootingStarsAvgSecondsMax, newValue))
            defaults.set(clamped, forKey: "ShootingStarsAvgSeconds")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsAvgSeconds")
            return (v >= Self.shootingStarsAvgSecondsMin && v <= Self.shootingStarsAvgSecondsMax) ? v : defaultShootingStarsAvgSeconds
        }
    }
    
    var shootingStarsDirectionMode: Int {
        set {
            let clamped = max(Self.shootingStarsDirectionModeMin, min(Self.shootingStarsDirectionModeMax, newValue))
            defaults.set(clamped, forKey: "ShootingStarsDirectionMode")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "ShootingStarsDirectionMode")
            return (Self.shootingStarsDirectionModeMin...Self.shootingStarsDirectionModeMax).contains(v) ? v : defaultShootingStarsDirectionMode
        }
    }
    
    var shootingStarsLength: Double {
        set {
            let clamped = max(Self.shootingStarsLengthMin, min(Self.shootingStarsLengthMax, newValue))
            defaults.set(clamped, forKey: "ShootingStarsLength")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsLength")
            return (v >= Self.shootingStarsLengthMin && v <= Self.shootingStarsLengthMax) ? v : defaultShootingStarsLength
        }
    }
    
    var shootingStarsSpeed: Double {
        set {
            let clamped = max(Self.shootingStarsSpeedMin, min(Self.shootingStarsSpeedMax, newValue))
            defaults.set(clamped, forKey: "ShootingStarsSpeed")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsSpeed")
            return (v >= Self.shootingStarsSpeedMin && v <= Self.shootingStarsSpeedMax) ? v : defaultShootingStarsSpeed
        }
    }
    
    var shootingStarsThickness: Double {
        set {
            let clamped = max(Self.shootingStarsThicknessMin, min(Self.shootingStarsThicknessMax, newValue))
            defaults.set(clamped, forKey: "ShootingStarsThickness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsThickness")
            return (v >= Self.shootingStarsThicknessMin && v <= Self.shootingStarsThicknessMax) ? v : defaultShootingStarsThickness
        }
    }
    
    var shootingStarsBrightness: Double {
        set {
            let clamped = max(Self.shootingStarsBrightnessMin, min(Self.shootingStarsBrightnessMax, newValue))
            defaults.set(clamped, forKey: "ShootingStarsBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsBrightness")
            return (v >= Self.shootingStarsBrightnessMin && v <= Self.shootingStarsBrightnessMax) ? v : defaultShootingStarsBrightness
        }
    }
    
    var shootingStarsTrailHalfLifeSeconds: Double {
        set {
            let clamped = max(Self.shootingStarsTrailHalfLifeMin, min(Self.shootingStarsTrailHalfLifeMax, newValue))
            defaults.set(clamped, forKey: "ShootingStarsTrailHalfLifeSeconds")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "ShootingStarsTrailHalfLifeSeconds") == nil {
                return defaultShootingStarsTrailHalfLifeSeconds
            }
            let v = defaults.double(forKey: "ShootingStarsTrailHalfLifeSeconds")
            return max(Self.shootingStarsTrailHalfLifeMin, min(Self.shootingStarsTrailHalfLifeMax, v))
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
            let clamped = max(Self.satellitesAvgSpawnSecondsMin, min(Self.satellitesAvgSpawnSecondsMax, newValue))
            defaults.set(clamped, forKey: "SatellitesAvgSpawnSeconds")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesAvgSpawnSeconds")
            if v.isNaN || v < Self.satellitesAvgSpawnSecondsMin || v > Self.satellitesAvgSpawnSecondsMax {
                return defaultSatellitesAvgSpawnSeconds
            }
            return v
        }
    }
    
    var satellitesSpeed: Double {
        set {
            let clamped = max(Self.satellitesSpeedMin, min(Self.satellitesSpeedMax, newValue))
            defaults.set(clamped, forKey: "SatellitesSpeed")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesSpeed")
            return (v >= Self.satellitesSpeedMin && v <= Self.satellitesSpeedMax) ? v : defaultSatellitesSpeed
        }
    }
    
    var satellitesSize: Double {
        set {
            let clamped = max(Self.satellitesSizeMin, min(Self.satellitesSizeMax, newValue))
            defaults.set(clamped, forKey: "SatellitesSize")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesSize")
            return (v >= Self.satellitesSizeMin && v <= Self.satellitesSizeMax) ? v : defaultSatellitesSize
        }
    }
    
    var satellitesBrightness: Double {
        set {
            let clamped = max(Self.satellitesBrightnessMin, min(Self.satellitesBrightnessMax, newValue))
            defaults.set(clamped, forKey: "SatellitesBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "SatellitesBrightness")
            return (v >= Self.satellitesBrightnessMin && v <= Self.satellitesBrightnessMax) ? v : defaultSatellitesBrightness
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
            let clamped = max(Self.satellitesTrailHalfLifeMin, min(Self.satellitesTrailHalfLifeMax, newValue))
            defaults.set(clamped, forKey: "SatellitesTrailHalfLifeSeconds")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "SatellitesTrailHalfLifeSeconds") == nil {
                return defaultSatellitesTrailHalfLifeSeconds
            }
            let v = defaults.double(forKey: "SatellitesTrailHalfLifeSeconds")
            return max(Self.satellitesTrailHalfLifeMin, min(Self.satellitesTrailHalfLifeMax, v))
        }
    }
    
    // MARK: - Runtime validation
    
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
        if phaseOverride.isNaN || phaseOverride < Self.moonPhaseValueMin || phaseOverride > Self.moonPhaseValueMax {
            os_log("Out-of-range MoonPhaseOverrideValue %.3f detected. Resetting to %.3f.",
                   log: log, type: .error, phaseOverride, defaultMoonPhaseOverrideValue)
            defaults.set(defaultMoonPhaseOverrideValue, forKey: "MoonPhaseOverrideValue")
            corrected = true
        }
        
        let percent = defaults.double(forKey: "MoonDiameterScreenWidthPercent")
        if percent.isNaN || percent < Self.moonDiameterPercentMin || percent > Self.moonDiameterPercentMax {
            os_log("Out-of-range MoonDiameterScreenWidthPercent %.5f detected. Resetting to default %.5f.",
                   log: log, type: .error, percent, defaultMoonDiameterScreenWidthPercent)
            defaults.set(defaultMoonDiameterScreenWidthPercent, forKey: "MoonDiameterScreenWidthPercent")
            corrected = true
        }
        
        if corrected { defaults.synchronize() }
    }
}
