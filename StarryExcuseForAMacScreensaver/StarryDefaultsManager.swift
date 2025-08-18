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
    private let defaultStarsPerUpdate = 80
    private let defaultBuildingHeight = 0.35
    private let defaultSecsBetweenClears = 120.0
    private let defaultMoonTraversalMinutes = 60
    private let defaultBuildingFrequency = 0.033
    private let defaultMoonMinRadius = 15
    private let defaultMoonMaxRadius = 60
    private let defaultMoonBrightBrightness = 1.0
    private let defaultMoonDarkBrightness = 0.15
    private let defaultMoonPhaseOverrideEnabled = false
    // 0 = New, 0.25 ≈ First Quarter, 0.5 = Full, 0.75 ≈ Last Quarter, 1.0 = New
    private let defaultMoonPhaseOverrideValue = 0.0
    // Debug toggle defaults
    private let defaultShowLightAreaTextureFillMask = false
    
    // Shooting Stars (Option Set C) defaults
    private let defaultShootingStarsEnabled = true
    private let defaultShootingStarsAvgSeconds = 7.0
    // Direction mode raw mapping:
    // 0 Random, 1 LtoR, 2 RtoL, 3 TL->BR, 4 TR->BL
    private let defaultShootingStarsDirectionMode = 0
    private let defaultShootingStarsLength: Double = 160
    private let defaultShootingStarsSpeed: Double = 600
    private let defaultShootingStarsThickness: Double = 2
    private let defaultShootingStarsBrightness: Double = 0.9
    private let defaultShootingStarsTrailDecay: Double = 0.92
    private let defaultShootingStarsDebugSpawnBounds = false
    
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
    }
    
    // MARK: - Stored properties (with range enforcement)
    
    var starsPerUpdate: Int {
        set { defaults.set(newValue, forKey: "StarsPerUpdate"); defaults.synchronize() }
        get {
            let v = defaults.integer(forKey: "StarsPerUpdate")
            return v > 0 ? v : defaultStarsPerUpdate
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
    
    // Building frequency (buildings per pixel width, used to derive count).
    // Practical range: >0 – about 0.2 (very dense). Clamp to 0.001 ... 1.0 for sanity.
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
    
    // Moon min radius (pixels). 5 .. 200.
    var moonMinRadius: Int {
        set {
            let clamped = max(5, min(200, newValue))
            defaults.set(clamped, forKey: "MoonMinRadius")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "MoonMinRadius")
            return (5...200).contains(v) ? v : defaultMoonMinRadius
        }
    }
    
    // Moon max radius (pixels). 5 .. 400.
    var moonMaxRadius: Int {
        set {
            let clamped = max(5, min(400, newValue))
            defaults.set(clamped, forKey: "MoonMaxRadius")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "MoonMaxRadius")
            return (5...400).contains(v) ? v : defaultMoonMaxRadius
        }
    }
    
    // Bright (illuminated) texture brightness factor. 0.2 .. 1.2
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
    
    // Dark (shadow) texture brightness factor. 0.0 .. 0.9
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
    
    // Phase override enabled
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
    
    // Phase override value (0.0 .. 1.0)
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
    
    // Debug: show illuminated mask (instead of bright texture)
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
    
    var shootingStarsTrailDecay: Double {
        set {
            let clamped = max(0.85, min(0.99, newValue))
            defaults.set(clamped, forKey: "ShootingStarsTrailDecay")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "ShootingStarsTrailDecay")
            return (v >= 0.85 && v <= 0.99) ? v : defaultShootingStarsTrailDecay
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
    
    // Ensure logical relation when saving (called by config UI)
    func normalizeMoonRadiusBounds() {
        if moonMinRadius > moonMaxRadius {
            let minR = moonMinRadius
            defaults.set(minR, forKey: "MoonMaxRadius")
            defaults.synchronize()
        }
    }
    
    // MARK: - Runtime validation (screensaver start-time)
    func validateAndCorrectMoonSettings(log: OSLog) {
        var corrected = false
        
        // 1. Radius ordering
        if moonMinRadius > moonMaxRadius {
            os_log("Invalid moon size settings detected (min %d > max %d). Reverting to defaults (%d, %d).",
                   log: log, type: .error,
                   moonMinRadius, moonMaxRadius,
                   defaultMoonMinRadius, defaultMoonMaxRadius)
            defaults.set(defaultMoonMinRadius, forKey: "MoonMinRadius")
            defaults.set(defaultMoonMaxRadius, forKey: "MoonMaxRadius")
            corrected = true
        }
        
        // 2. Brightness ordering
        if moonBrightBrightness < moonDarkBrightness {
            os_log("Invalid moon brightness settings (bright %.3f < dark %.3f). Reverting to defaults (bright %.2f, dark %.2f).",
                   log: log, type: .error,
                   moonBrightBrightness, moonDarkBrightness,
                   defaultMoonBrightBrightness, defaultMoonDarkBrightness)
            defaults.set(defaultMoonBrightBrightness, forKey: "MoonBrightBrightness")
            defaults.set(defaultMoonDarkBrightness, forKey: "MoonDarkBrightness")
            corrected = true
        }
        
        // 3. Radius hard range revalidation
        let minR = defaults.integer(forKey: "MoonMinRadius")
        if !(5...200).contains(minR) {
            os_log("Out-of-range MoonMinRadius %d detected at runtime. Resetting to %d.",
                   log: log, type: .error, minR, defaultMoonMinRadius)
            defaults.set(defaultMoonMinRadius, forKey: "MoonMinRadius")
            corrected = true
        }
        let maxR = defaults.integer(forKey: "MoonMaxRadius")
        if !(5...400).contains(maxR) {
            os_log("Out-of-range MoonMaxRadius %d detected at runtime. Resetting to %d.",
                   log: log, type: .error, maxR, defaultMoonMaxRadius)
            defaults.set(defaultMoonMaxRadius, forKey: "MoonMaxRadius")
            corrected = true
        }
        
        // 4. Phase override sanity
        let phaseOverride = defaults.double(forKey: "MoonPhaseOverrideValue")
        if phaseOverride.isNaN || phaseOverride < 0.0 || phaseOverride > 1.0 {
            os_log("Out-of-range MoonPhaseOverrideValue %.3f detected. Resetting to %.3f.",
                   log: log, type: .error, phaseOverride, defaultMoonPhaseOverrideValue)
            defaults.set(defaultMoonPhaseOverrideValue, forKey: "MoonPhaseOverrideValue")
            corrected = true
        }
        
        if corrected { defaults.synchronize() }
    }
}
