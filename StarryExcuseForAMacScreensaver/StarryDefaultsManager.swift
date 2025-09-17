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
    
    // MARK: - Defensive helpers
    
    // Returns NSNumber strictly (rejects strings, etc.)
    private func safeNumber(_ key: String) -> NSNumber? {
        guard let obj = defaults.object(forKey: key) else { return nil }
        if let num = obj as? NSNumber {
            let d = num.doubleValue
            if d.isNaN || d.isInfinite {
                return nil
            }
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
    
    // Generic validation (range inclusive). If invalid or out-of-range → defaultValue.
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
    
    private func setClampedDouble(_ value: Double, key: String, min: Double, max: Double) {
        let clamped = max(min, min(max, value))
        defaults.set(clamped, forKey: key)
        defaults.synchronize()
    }
    
    private func setClampedInt(_ value: Int, key: String, min: Int, max: Int) {
        let clamped = max(min, min(max, value))
        defaults.set(clamped, forKey: key)
        defaults.synchronize()
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
    
    // MARK: - Stored properties (defensive getters)
    
    var starsPerSecond: Double {
        set {
            let v = max(Self.starsPerSecondMin, newValue)
            defaults.set(v, forKey: "StarsPerSecond")
            // Keep legacy key in sync (rounded)
            defaults.set(Int(round(v / 10.0)), forKey: "StarsPerUpdate")
            defaults.synchronize()
        }
        get {
            if let v = safeDouble("StarsPerSecond"), v >= Self.starsPerSecondMin {
                return v
            }
            // legacy fallback
            if let legacy = safeInt("StarsPerUpdate"), legacy >= 0 {
                return Double(legacy) * 10.0
            }
            return defaultStarsPerSecond
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
            if let v = safeInt("StarsPerUpdate"), v >= 0 {
                return v
            }
            // derive from starsPerSecond (which already defends)
            return Int(max(0, round(starsPerSecond / 10.0)))
        }
    }
    
    var buildingLightsPerUpdate: Int {
        set {
            let v = max(0, newValue)
            defaults.set(v, forKey: "BuildingLightsPerUpdate")
            defaults.synchronize()
        }
        get {
            if let v = safeInt("BuildingLightsPerUpdate"), v >= 0 {
                return v
            }
            return defaultBuildingLightsPerUpdate
        }
    }
    
    var buildingLightsPerSecond: Double {
        set {
            let v = max(Self.buildingLightsPerSecondMin, newValue)
            defaults.set(v, forKey: "BuildingLightsPerSecond")
            defaults.synchronize()
        }
        get {
            if let v = safeDouble("BuildingLightsPerSecond"), v >= Self.buildingLightsPerSecondMin {
                return v
            }
            // legacy fallback
            return Double(buildingLightsPerUpdate) * 10.0
        }
    }
    
    var buildingHeight: Double {
        set { setClampedDouble(newValue, key: "BuildingHeight", min: Self.buildingHeightMin, max: Self.buildingHeightMax) }
        get {
            let v = validatedDouble(safeDouble("BuildingHeight"),
                                    min: Self.buildingHeightMin,
                                    max: Self.buildingHeightMax,
                                    defaultValue: defaultBuildingHeight)
            return v
        }
    }
    
    var secsBetweenClears: Double {
        set {
            let v = max(Self.secsBetweenClearsMin, newValue)
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
            return validatedInt(safeInt("MoonTraversalMinutes"),
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
            let v = validatedDouble(safeDouble("MoonDiameterScreenWidthPercent"),
                                    min: Self.moonDiameterPercentMin,
                                    max: Self.moonDiameterPercentMax,
                                    defaultValue: defaultMoonDiameterScreenWidthPercent)
            return v
        }
    }
    
    var moonBrightBrightness: Double {
        set { setClampedDouble(newValue, key: "MoonBrightBrightness", min: Self.moonBrightBrightnessMin, max: Self.moonBrightBrightnessMax) }
        get {
            return validatedDouble(safeDouble("MoonBrightBrightness"),
                                   min: Self.moonBrightBrightnessMin,
                                   max: Self.moonBrightBrightnessMax,
                                   defaultValue: defaultMoonBrightBrightness)
        }
    }
    
    var moonDarkBrightness: Double {
        set { setClampedDouble(newValue, key: "MoonDarkBrightness", min: Self.moonDarkBrightnessMin, max: Self.moonDarkBrightnessMax) }
        get {
            return validatedDouble(safeDouble("MoonDarkBrightness"),
                                   min: Self.moonDarkBrightnessMin,
                                   max: Self.moonDarkBrightnessMax,
                                   defaultValue: defaultMoonDarkBrightness)
        }
    }
    
    var moonPhaseOverrideEnabled: Bool {
        set {
            defaults.set(newValue, forKey: "MoonPhaseOverrideEnabled")
            defaults.synchronize()
        }
        get {
            return safeBool("MoonPhaseOverrideEnabled") ?? defaultMoonPhaseOverrideEnabled
        }
    }
    
    var moonPhaseOverrideValue: Double {
        set { setClampedDouble(newValue, key: "MoonPhaseOverrideValue", min: Self.moonPhaseValueMin, max: Self.moonPhaseValueMax) }
        get {
            return validatedDouble(safeDouble("MoonPhaseOverrideValue"),
                                   min: Self.moonPhaseValueMin,
                                   max: Self.moonPhaseValueMax,
                                   defaultValue: defaultMoonPhaseOverrideValue)
        }
    }
    
    var showLightAreaTextureFillMask: Bool {
        set {
            defaults.set(newValue, forKey: "ShowLightAreaTextureFillMask")
            defaults.synchronize()
        }
        get {
            return safeBool("ShowLightAreaTextureFillMask") ?? defaultShowLightAreaTextureFillMask
        }
    }
    
    var debugOverlayEnabled: Bool {
        set {
            defaults.set(newValue, forKey: "DebugOverlayEnabled")
            defaults.synchronize()
        }
        get {
            return safeBool("DebugOverlayEnabled") ?? defaultDebugOverlayEnabled
        }
    }
    
    // MARK: - Shooting Stars Settings
    
    var shootingStarsEnabled: Bool {
        set { defaults.set(newValue, forKey: "ShootingStarsEnabled"); defaults.synchronize() }
        get { safeBool("ShootingStarsEnabled") ?? defaultShootingStarsEnabled }
    }
    
    var shootingStarsAvgSeconds: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsAvgSeconds", min: Self.shootingStarsAvgSecondsMin, max: Self.shootingStarsAvgSecondsMax) }
        get {
            return validatedDouble(safeDouble("ShootingStarsAvgSeconds"),
                                   min: Self.shootingStarsAvgSecondsMin,
                                   max: Self.shootingStarsAvgSecondsMax,
                                   defaultValue: defaultShootingStarsAvgSeconds)
        }
    }
    
    var shootingStarsDirectionMode: Int {
        set { setClampedInt(newValue, key: "ShootingStarsDirectionMode", min: Self.shootingStarsDirectionModeMin, max: Self.shootingStarsDirectionModeMax) }
        get {
            return validatedInt(safeInt("ShootingStarsDirectionMode"),
                                min: Self.shootingStarsDirectionModeMin,
                                max: Self.shootingStarsDirectionModeMax,
                                defaultValue: defaultShootingStarsDirectionMode)
        }
    }
    
    var shootingStarsLength: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsLength", min: Self.shootingStarsLengthMin, max: Self.shootingStarsLengthMax) }
        get {
            return validatedDouble(safeDouble("ShootingStarsLength"),
                                   min: Self.shootingStarsLengthMin,
                                   max: Self.shootingStarsLengthMax,
                                   defaultValue: defaultShootingStarsLength)
        }
    }
    
    var shootingStarsSpeed: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsSpeed", min: Self.shootingStarsSpeedMin, max: Self.shootingStarsSpeedMax) }
        get {
            return validatedDouble(safeDouble("ShootingStarsSpeed"),
                                   min: Self.shootingStarsSpeedMin,
                                   max: Self.shootingStarsSpeedMax,
                                   defaultValue: defaultShootingStarsSpeed)
        }
    }
    
    var shootingStarsThickness: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsThickness", min: Self.shootingStarsThicknessMin, max: Self.shootingStarsThicknessMax) }
        get {
            return validatedDouble(safeDouble("ShootingStarsThickness"),
                                   min: Self.shootingStarsThicknessMin,
                                   max: Self.shootingStarsThicknessMax,
                                   defaultValue: defaultShootingStarsThickness)
        }
    }
    
    var shootingStarsBrightness: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsBrightness", min: Self.shootingStarsBrightnessMin, max: Self.shootingStarsBrightnessMax) }
        get {
            return validatedDouble(safeDouble("ShootingStarsBrightness"),
                                   min: Self.shootingStarsBrightnessMin,
                                   max: Self.shootingStarsBrightnessMax,
                                   defaultValue: defaultShootingStarsBrightness)
        }
    }
    
    var shootingStarsTrailHalfLifeSeconds: Double {
        set { setClampedDouble(newValue, key: "ShootingStarsTrailHalfLifeSeconds", min: Self.shootingStarsTrailHalfLifeMin, max: Self.shootingStarsTrailHalfLifeMax) }
        get {
            return validatedDouble(safeDouble("ShootingStarsTrailHalfLifeSeconds"),
                                   min: Self.shootingStarsTrailHalfLifeMin,
                                   max: Self.shootingStarsTrailHalfLifeMax,
                                   defaultValue: defaultShootingStarsTrailHalfLifeSeconds)
        }
    }
    
    var shootingStarsDebugShowSpawnBounds: Bool {
        set { defaults.set(newValue, forKey: "ShootingStarsDebugShowSpawnBounds"); defaults.synchronize() }
        get { safeBool("ShootingStarsDebugShowSpawnBounds") ?? defaultShootingStarsDebugSpawnBounds }
    }
    
    // MARK: - Satellites Settings
    
    var satellitesEnabled: Bool {
        set { defaults.set(newValue, forKey: "SatellitesEnabled"); defaults.synchronize() }
        get { safeBool("SatellitesEnabled") ?? defaultSatellitesEnabled }
    }
    
    var satellitesAvgSpawnSeconds: Double {
        set { setClampedDouble(newValue, key: "SatellitesAvgSpawnSeconds", min: Self.satellitesAvgSpawnSecondsMin, max: Self.satellitesAvgSpawnSecondsMax) }
        get {
            return validatedDouble(safeDouble("SatellitesAvgSpawnSeconds"),
                                   min: Self.satellitesAvgSpawnSecondsMin,
                                   max: Self.satellitesAvgSpawnSecondsMax,
                                   defaultValue: defaultSatellitesAvgSpawnSeconds)
        }
    }
    
    var satellitesSpeed: Double {
        set { setClampedDouble(newValue, key: "SatellitesSpeed", min: Self.satellitesSpeedMin, max: Self.satellitesSpeedMax) }
        get {
            return validatedDouble(safeDouble("SatellitesSpeed"),
                                   min: Self.satellitesSpeedMin,
                                   max: Self.satellitesSpeedMax,
                                   defaultValue: defaultSatellitesSpeed)
        }
    }
    
    var satellitesSize: Double {
        set { setClampedDouble(newValue, key: "SatellitesSize", min: Self.satellitesSizeMin, max: Self.satellitesSizeMax) }
        get {
            return validatedDouble(safeDouble("SatellitesSize"),
                                   min: Self.satellitesSizeMin,
                                   max: Self.satellitesSizeMax,
                                   defaultValue: defaultSatellitesSize)
        }
    }
    
    var satellitesBrightness: Double {
        set { setClampedDouble(newValue, key: "SatellitesBrightness", min: Self.satellitesBrightnessMin, max: Self.satellitesBrightnessMax) }
        get {
            return validatedDouble(safeDouble("SatellitesBrightness"),
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
            return validatedDouble(safeDouble("SatellitesTrailHalfLifeSeconds"),
                                   min: Self.satellitesTrailHalfLifeMin,
                                   max: Self.satellitesTrailHalfLifeMax,
                                   defaultValue: defaultSatellitesTrailHalfLifeSeconds)
        }
    }
    
    // MARK: - Runtime validation (kept, but getters are already defensive)
    
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
