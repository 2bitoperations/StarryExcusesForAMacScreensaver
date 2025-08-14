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
    private let defaultMoonMinRadius = 15
    private let defaultMoonMaxRadius = 60
    private let defaultMoonBrightBrightness = 1.0
    private let defaultMoonDarkBrightness = 0.15
    private let defaultMoonPhaseOverrideEnabled = false
    // 0 = New, 0.25 ≈ First Quarter, 0.5 = Full, 0.75 ≈ Last Quarter, 1.0 = New
    private let defaultMoonPhaseOverrideValue = 0.0
    // Debug toggle default
    private let defaultShowCrescentClipMask = false
    
    init() {
        let identifier = Bundle(for: StarryDefaultsManager.self).bundleIdentifier
        defaults = ScreenSaverDefaults.init(forModuleWithName: identifier!)!
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
    
    // Debug: show crescent clip mask
    var showCrescentClipMask: Bool {
        set {
            defaults.set(newValue, forKey: "ShowCrescentClipMask")
            defaults.synchronize()
        }
        get {
            if defaults.object(forKey: "ShowCrescentClipMask") == nil {
                return defaultShowCrescentClipMask
            }
            return defaults.bool(forKey: "ShowCrescentClipMask")
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
