import Foundation
import ScreenSaver
import os

class StarryDefaultsManager {
    var defaults: UserDefaults
    
    // MARK: - Public range constants (single source of truth for UI components)
    
    // Star density (normalized 0.0 -> 1.0 of maximum fraction that yields 1600 stars/sec on 3008x1692)
    static let starSpawnFractionOfMaxMin: Double = 0.0
    static let starSpawnFractionOfMaxMax: Double = 1.0
    
    // Building lights density (normalized 0.0 -> 1.0 of maximum fraction that yields 600 lights/sec on 3008x1692)
    static let buildingLightsSpawnFractionOfMaxMin: Double = 0.0
    static let buildingLightsSpawnFractionOfMaxMax: Double = 1.0
    
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
    // Star density: 0.5 ≈ previous default 800 stars/sec at reference screen (half of 1600).
    private let defaultStarSpawnFractionOfMax = 0.5
    
    // Building lights density: 0.25 ≈ previous default 150 lights/sec at reference (150 / 600).
    private let defaultBuildingLightsSpawnFractionOfMax = 0.25
    
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
    
    // MARK: - Defensive helpers
    
    private func safeNumber(_ key: String) -> NSNumber? {
        guard let obj = defaults.object(forKey: key) else { return nil }
        if let num = obj as? NSNumber {
            let d = num.doubleValue
            if d.isNaN || d.isInfinite { return nil }
            return num
        }
        return nil
    }
    private func safeDouble(_ key: String) -> Double? {
        guard let n = safeNumber(key) else { return nil }
        return n.doubleValue
    }
    private func safeInt(_ key: String) -> Int? {
        guard let n = safeNumber(key) else { return nil }
        return n.intValue
    }
    private func safeBool(_ key: String) -> Bool? {
        guard let obj = defaults.object(forKey: key) else { return nil }
        if let b = obj as? Bool { return b }
        if let n = obj as? NSNumber { return n.boolValue }
        return nil
    }
    
    private func validatedDouble(_ value: Double?, min: Double, max: Double, defaultValue: Double) -> Double {
        guard let v = value, !v.isNaN, !v.isInfinite else { return defaultValue }
        if v < min || v > max { return defaultValue }
        return v
    }
    private func validatedInt(_ value: Int?, min: Int, max: Int, defaultValue: Int) -> Int {
        guard let v = value else { return defaultValue }
        if v < min || v > max { return defaultValue }
        return v
    }
    
    private func setClampedDouble(_ value: Double, key: String, min lower: Double, max upper: Double) {
        let clamped = Swift.max(lower, Swift.min(upper, value))
        defaults.set(clamped, forKey: key)
        defaults.synchronize()
    }
    private func setClampedInt(_ value: Int, key: String, min lower: Int, max upper: Int) {
        let clamped = Swift.max(lower, Swift.min(upper, value))
        defaults.set(clamped, forKey: key)
        defaults.synchronize()
    }
    
    // MARK: - Migration
    // No legacy migration required for building lights or star density beyond initial fraction-based keys.
    
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
                let f = Swift.max(0.0001, Swift.min(0.9999, factor))
                let hl = Swift.max(Self.shootingStarsTrailHalfLifeMin,
                                   Swift.min(Self.shootingStarsTrailHalfLifeMax,
                                             log(0.5) / (fps * log(f))))
                defaults.set(hl, forKey: "ShootingStarsTrailHalfLifeSeconds")
            } else {
                defaults.set(defaultShootingStarsTrailHalfLifeSeconds, forKey: "ShootingStarsTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        } else {
            let hl = defaults.double(forKey: "ShootingStarsTrailHalfLifeSeconds")
            let clamped = Swift.max(Self.shootingStarsTrailHalfLifeMin,
                                    Swift.min(Self.shootingStarsTrailHalfLifeMax, hl))
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
                    let f = Swift.max(0.0001, Swift.min(0.9999, v))
                    hl = Swift.max(Self.shootingStarsTrailHalfLifeMin,
                                   Swift.min(Self.shootingStarsTrailHalfLifeMax,
                                             log(0.5) / (fps * log(f))))
                } else {
                    let t = Swift.max(0.01, Swift.min(120.0, v))
                    hl = t * log(2.0) / log(100.0)
                    hl = Swift.max(Self.shootingStarsTrailHalfLifeMin,
                                   Swift.min(Self.shootingStarsTrailHalfLifeMax, hl))
                }
                defaults.set(hl, forKey: "SatellitesTrailHalfLifeSeconds")
            } else {
                defaults.set(defaultSatellitesTrailHalfLifeSeconds, forKey: "SatellitesTrailHalfLifeSeconds")
            }
            defaults.synchronize()
        }
        
        let oldHL = defaults.double(forKey: "SatellitesTrailHalfLifeSeconds")
        if oldHL.isNaN || oldHL < Self.satellitesTrailHalfLifeMin || oldHL > Self.satellitesTrailHalfLifeMax {
            let clamped = Swift.max(Self.satellitesTrailHalfLifeMin,
                                    Swift.min(Self.satellitesTrailHalfLifeMax,
                                              oldHL.isNaN ? defaultSatellitesTrailHalfLifeSeconds : oldHL))
            defaults.set(clamped == oldHL ? clamped : (oldHL.isNaN ? defaultSatellitesTrailHalfLifeSeconds : clamped),
                         forKey: "SatellitesTrailHalfLifeSeconds")
            defaults.synchronize()
        }
        
        // Initialize star fraction if missing.
        if defaults.object(forKey: "StarSpawnFractionOfMax") == nil {
            defaults.set(defaultStarSpawnFractionOfMax, forKey: "StarSpawnFractionOfMax")
            defaults.synchronize()
        }
        
        // Initialize building lights fraction if missing.
        if defaults.object(forKey: "BuildingLightsSpawnFractionOfMax") == nil {
            defaults.set(defaultBuildingLightsSpawnFractionOfMax, forKey: "BuildingLightsSpawnFractionOfMax")
            defaults.synchronize()
        }
    }
    
    // MARK: - Stored properties (defensive getters)
    
    var starSpawnFractionOfMax: Double {
        set { setClampedDouble(newValue, key: "StarSpawnFractionOfMax", min: Self.starSpawnFractionOfMaxMin, max: Self.starSpawnFractionOfMaxMax) }
        get {
            return validatedDouble(safeDouble("StarSpawnFractionOfMax"),
                                   min: Self.starSpawnFractionOfMaxMin,
                                   max: Self.starSpawnFractionOfMaxMax,
                                   defaultValue: defaultStarSpawnFractionOfMax)
        }
    }
    
    var buildingLightsSpawnFractionOfMax: Double {
        set { setClampedDouble(newValue, key: "BuildingLightsSpawnFractionOfMax", min: Self.buildingLightsSpawnFractionOfMaxMin, max: Self.buildingLightsSpawnFractionOfMaxMax) }
        get {
            validatedDouble(safeDouble("BuildingLightsSpawnFractionOfMax"),
                            min: Self.buildingLightsSpawnFractionOfMaxMin,
                            max: Self.buildingLightsSpawnFractionOfMaxMax,
                            defaultValue: defaultBuildingLightsSpawnFractionOfMax)
        }
    }
    
    var buildingHeight: Double {
        set { setClampedDouble(newValue, key: "BuildingHeight", min: Self.buildingHeightMin, max: Self.buildingHeightMax) }
        get {
            validatedDouble(safeDouble("BuildingHeight"),
                            min: Self.buildingHeightMin,
                            max: Self.buildingHeightMax,
                            defaultValue: defaultBuildingHeight)
        }
    }
    
    var secsBetweenClears: Double {
        set {
            let v = Swift.max(Self.secsBetweenClearsMin, newValue)
            defaults.set(v, forKey: "SecsBetweenClears")
            defaults.synchronize()
        }
        get {
            if let v = safeDouble("SecsBetweenClears"), v >= Self.secsBetweenClearsMin {
                return v
            }
            return defaultSecsBetweenClears
        }
    }
    
    var moonTraversalMinutes: Int {
        set { setClampedInt(newValue, key: "MoonTraversalMinutes", min: Self.moonTraversalMinutesMin, max: Self.moonTraversalMinutesMax) }
        get {
            validatedInt(safeInt("MoonTraversalMinutes"),
                         min: Self.moonTraversalMinutesMin,
                         max: Self.moonTraversalMinutesMax,
                         defaultValue: defaultMoonTraversalMinutes)
        }
    }
    
    var buildingFrequency: Double {
        set { setClampedDouble(newValue, key: "BuildingFrequency", min: Self.buildingFrequencyMin, max: Self.buildingFrequencyMax) }
        get {
            let v = safeDouble("BuildingFrequency")
            if let val = v, !val.isNaN, !val.isInfinite,
               val >= Self.buildingFrequencyMin, val <= Self.buildingFrequencyMax {
                return val
            }
            return defaultBuildingFrequency
        }
    }
    
    var moonDiameterScreenWidthPercent: Double {
        set { setClampedDouble(newValue, key: "MoonDiameterScreenWidthPercent", min: Self.moonDiameterPercentMin, max: Self.moonDiameterPercentMax) }
        get {
            validatedDouble(safeDouble("MoonDiameterScreenWidthPercent"),
                            min: Self.moonDiameterPercentMin,
                            max: Self.moonDiameterPercentMax,
                            defaultValue: defaultMoonDiameterScreenWidthPercent)
        }
    }
    
    var moonBrightBrightness: Double {
        set { setClampedDouble(newValue, key: "MoonBrightBrightness", min: Self.moonBrightBrightnessMin, max: Self.moonBrightBrightnessMax) }
        get {
            validatedDouble(safeDouble("MoonBrightBrightness"),
                            min: Self.moonBrightBrightnessMin,
                            max: Self.moonBrightBrightnessMax,
                            defaultValue: defaultMoonBrightBrightness)
        }
    }
    
    var moonDarkBrightness: Double {
        set { setClampedDouble(newValue, key: "MoonDarkBrightness", min: Self.moonDarkBrightnessMin, max: Self.moonDarkBrightnessMax) }
        get {
            validatedDouble(safeDouble("MoonDarkBrightness"),
                            min: Self.moonDarkBrightnessMin,
                            max: Self.moonDarkBrightnessMax,
                            defaultValue: defaultMoonDarkBrightness)
        }
    }
    
    var moonPhaseOverrideEnabled: Bool {
        set { defaults.set(newValue, forKey: "MoonPhaseOverrideEnabled"); defaults.synchronize() }
        get { safeBool("MoonPhaseOverrideEnabled") ?? defaultMoonPhaseOverrideEnabled }
    }
    
    var moonPhaseOverrideValue: Double {
        set { setClampedDouble(newValue, key: "MoonPhaseOverrideValue", min: Self.moonPhaseValueMin, max: Self.moonPhaseValueMax) }
        get {
            validatedDouble(safeDouble("MoonPhaseOverrideValue"),
                            min: Self.moonPhaseValueMin,
                            max: Self.moonPhaseValueMax,
                            defaultValue: defaultMoonPhaseOverrideValue)
        }
    }
    
    var showLightAreaTextureFillMask: Bool {
        set { defaults.set(newValue, forKey: "ShowLightAreaTextureFillMask"); defaults.synchronize() }
        get { safeBool("ShowLightAreaTextureFillMask") ?? defaultShowLightAreaTextureFillMask }
    }
    
    var debugOverlayEnabled: Bool {
        set { defaults.set(newValue, forKey: "DebugOverlayEnabled"); defaults.synchronize() }
        get { safeBool("DebugOverlayEnabled") ?? defaultDebugOverlayEnabled }
    }
    
    // MARK: - Shooting Stars
    
    var shootingStarsEnabled: Bool {
        set { defaults.set(newValue, forKey: "ShootingStarsEnabled"); defaults.synchronize() }
        get { safeBool("ShootingStarsEnabled") ?? defaultShootingStarsEnabled }
    }
    var shootingStarsAvgSeconds: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsAvgSeconds", min: Self.shootingStarsAvgSecondsMin, max: Self.shootingStarsAvgSecondsMax) }
        get {
            validatedDouble(safeDouble("ShootingStarsAvgSeconds"),
                            min: Self.shootingStarsAvgSecondsMin,
                            max: Self.shootingStarsAvgSecondsMax,
                            defaultValue: defaultShootingStarsAvgSeconds)
        }
    }
    var shootingStarsDirectionMode: Int {
        set { setClampedInt(newValue, key: "ShootingStarsDirectionMode", min: Self.shootingStarsDirectionModeMin, max: Self.shootingStarsDirectionModeMax) }
        get {
            validatedInt(safeInt("ShootingStarsDirectionMode"),
                         min: Self.shootingStarsDirectionModeMin,
                         max: Self.shootingStarsDirectionModeMax,
                         defaultValue: defaultShootingStarsDirectionMode)
        }
    }
    var shootingStarsLength: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsLength", min: Self.shootingStarsLengthMin, max: Self.shootingStarsLengthMax) }
        get {
            validatedDouble(safeDouble("ShootingStarsLength"),
                            min: Self.shootingStarsLengthMin,
                            max: Self.shootingStarsLengthMax,
                            defaultValue: defaultShootingStarsLength)
        }
    }
    var shootingStarsSpeed: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsSpeed", min: Self.shootingStarsSpeedMin, max: Self.shootingStarsSpeedMax) }
        get {
            validatedDouble(safeDouble("ShootingStarsSpeed"),
                            min: Self.shootingStarsSpeedMin,
                            max: Self.shootingStarsSpeedMax,
                            defaultValue: defaultShootingStarsSpeed)
        }
    }
    var shootingStarsThickness: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsThickness", min: Self.shootingStarsThicknessMin, max: Self.shootingStarsThicknessMax) }
        get {
            validatedDouble(safeDouble("ShootingStarsThickness"),
                            min: Self.shootingStarsThicknessMin,
                            max: Self.shootingStarsThicknessMax,
                            defaultValue: defaultShootingStarsThickness)
        }
    }
    var shootingStarsBrightness: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsBrightness", min: Self.shootingStarsBrightnessMin, max: Self.shootingStarsBrightnessMax) }
        get {
            validatedDouble(safeDouble("ShootingStarsBrightness"),
                            min: Self.shootingStarsBrightnessMin,
                            max: Self.shootingStarsBrightnessMax,
                            defaultValue: defaultShootingStarsBrightness)
        }
    }
    var shootingStarsTrailHalfLifeSeconds: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsTrailHalfLifeSeconds", min: Self.shootingStarsTrailHalfLifeMin, max: Self.shootingStarsTrailHalfLifeMax) }
        get {
            validatedDouble(safeDouble("ShootingStarsTrailHalfLifeSeconds"),
                            min: Self.shootingStarsTrailHalfLifeMin,
                            max: Self.shootingStarsTrailHalfLifeMax,
                            defaultValue: defaultShootingStarsTrailHalfLifeSeconds)
        }
    }
    var shootingStarsDebugShowSpawnBounds: Bool {
        set { defaults.set(newValue, forKey: "ShootingStarsDebugShowSpawnBounds"); defaults.synchronize() }
        get { safeBool("ShootingStarsDebugShowSpawnBounds") ?? defaultShootingStarsDebugSpawnBounds }
    }
    
    // MARK: - Satellites
    
    var satellitesEnabled: Bool {
        set { defaults.set(newValue, forKey: "SatellitesEnabled"); defaults.synchronize() }
        get { safeBool("SatellitesEnabled") ?? defaultSatellitesEnabled }
    }
    var satellitesAvgSpawnSeconds: Double {
        set { setClampedDouble(newValue, key: "SatellitesAvgSpawnSeconds", min: Self.satellitesAvgSpawnSecondsMin, max: Self.satellitesAvgSpawnSecondsMax) }
        get {
            validatedDouble(safeDouble("SatellitesAvgSpawnSeconds"),
                            min: Self.satellitesAvgSpawnSecondsMin,
                            max: Self.satellitesAvgSpawnSecondsMax,
                            defaultValue: defaultSatellitesAvgSpawnSeconds)
        }
    }
    var satellitesSpeed: Double {
        set { setClampedDouble(newValue, key: "SatellitesSpeed", min: Self.satellitesSpeedMin, max: Self.satellitesSpeedMax) }
        get {
            validatedDouble(safeDouble("SatellitesSpeed"),
                            min: Self.satellitesSpeedMin,
                            max: Self.satellitesSpeedMax,
                            defaultValue: defaultSatellitesSpeed)
        }
    }
    var satellitesSize: Double {
        set { setClampedDouble(newValue, key: "SatellitesSize", min: Self.satellitesSizeMin, max: Self.satellitesSizeMax) }
        get {
            validatedDouble(safeDouble("SatellitesSize"),
                            min: Self.satellitesSizeMin,
                            max: Self.satellitesSizeMax,
                            defaultValue: defaultSatellitesSize)
        }
    }
    var satellitesBrightness: Double {
        set { setClampedDouble(newValue, key: "SatellitesBrightness", min: Self.satellitesBrightnessMin, max: Self.satellitesBrightnessMax) }
        get {
            validatedDouble(safeDouble("SatellitesBrightness"),
                            min: Self.satellitesBrightnessMin,
                            max: Self.satellitesBrightnessMax,
                            defaultValue: defaultSatellitesBrightness)
        }
    }
    var satellitesTrailing: Bool {
        set { defaults.set(newValue, forKey: "SatellitesTrailing"); defaults.synchronize() }
        get { safeBool("SatellitesTrailing") ?? defaultSatellitesTrailing }
    }
    var satellitesTrailHalfLifeSeconds: Double {
        set { setClampedDouble(newValue, key: "SatellitesTrailHalfLifeSeconds", min: Self.satellitesTrailHalfLifeMin, max: Self.satellitesTrailHalfLifeMax) }
        get {
            validatedDouble(safeDouble("SatellitesTrailHalfLifeSeconds"),
                            min: Self.satellitesTrailHalfLifeMin,
                            max: Self.satellitesTrailHalfLifeMax,
                            defaultValue: defaultSatellitesTrailHalfLifeSeconds)
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
