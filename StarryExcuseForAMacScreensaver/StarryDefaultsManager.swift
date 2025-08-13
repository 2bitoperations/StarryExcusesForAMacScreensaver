//
//  StarryConfigSheetManager.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 5/2/19.
//  Copyright © 2019 Andrew Malota. All rights reserved.
//

import Foundation
import ScreenSaver

class StarryDefaultsManager {
    var defaults: UserDefaults
    
    init() {
        let identifier = Bundle(for: StarryDefaultsManager.self).bundleIdentifier
        defaults = ScreenSaverDefaults.init(forModuleWithName: identifier!)!
    }
    
    var starsPerUpdate: Int {
        set { defaults.set(newValue, forKey: "StarsPerUpdate"); defaults.synchronize() }
        get {
            let v = defaults.integer(forKey: "StarsPerUpdate")
            return v > 0 ? v : 80
        }
    }
    
    var buildingHeight: Double {
        set { defaults.set(newValue, forKey: "BuildingHeight"); defaults.synchronize() }
        get {
            let v = defaults.double(forKey: "BuildingHeight")
            return (v > 0 && v < 1) ? v : 0.35
        }
    }
    
    var secsBetweenClears: Double {
        set { defaults.set(newValue, forKey: "SecsBetweenClears"); defaults.synchronize() }
        get {
            let v = defaults.double(forKey: "SecsBetweenClears")
            return v > 0 ? v : 120
        }
    }
    
    // Moon traversal duration (minutes). 1 .. 720 (12h). Default 60.
    var moonTraversalMinutes: Int {
        set {
            let clamped = max(1, min(720, newValue))
            defaults.set(clamped, forKey: "MoonTraversalMinutes")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "MoonTraversalMinutes")
            return (1...720).contains(v) ? v : 60
        }
    }
    
    // Moon min radius (pixels). 5 .. 200. Default 15.
    var moonMinRadius: Int {
        set {
            let clamped = max(5, min(200, newValue))
            defaults.set(clamped, forKey: "MoonMinRadius")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "MoonMinRadius")
            return (5...200).contains(v) ? v : 15
        }
    }
    
    // Moon max radius (pixels). >= min, up to 400. Default 60.
    var moonMaxRadius: Int {
        set {
            let clamped = max(5, min(400, newValue))
            defaults.set(clamped, forKey: "MoonMaxRadius")
            defaults.synchronize()
        }
        get {
            let v = defaults.integer(forKey: "MoonMaxRadius")
            return (5...400).contains(v) ? v : 60
        }
    }
    
    // Bright (illuminated) texture brightness factor. 0.2 .. 1.2 default 1.0
    var moonBrightBrightness: Double {
        set {
            let clamped = max(0.2, min(1.2, newValue))
            defaults.set(clamped, forKey: "MoonBrightBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonBrightBrightness")
            return (v >= 0.2 && v <= 1.2) ? v : 1.0
        }
    }
    
    // Dark (shadow) texture brightness factor. 0.0 .. 0.9 default 0.15
    var moonDarkBrightness: Double {
        set {
            let clamped = max(0.0, min(0.9, newValue))
            defaults.set(clamped, forKey: "MoonDarkBrightness")
            defaults.synchronize()
        }
        get {
            let v = defaults.double(forKey: "MoonDarkBrightness")
            return (v >= 0.0 && v <= 0.9) ? v : 0.15
        }
    }
    
    // Ensure logical relation when saving
    func normalizeMoonRadiusBounds() {
        if moonMinRadius > moonMaxRadius {
            let minR = moonMinRadius
            defaults.set(minR, forKey: "MoonMaxRadius")
            defaults.synchronize()
        }
    }
}
