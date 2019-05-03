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
        set(newCount) {
            self.defaults.set(newCount, forKey: "StarsPerUpdate")
            defaults.synchronize()
        }
        get {
            let storedValue = self.defaults.integer(forKey: "StarsPerUpdate")
            if (storedValue > 0) {
                return storedValue
            } else {
                return 80
            }
        }
    }
    
    var buildingHeight: Double {
        set(newValue) {
            self.defaults.set(newValue, forKey: "BuildingHeight")
            defaults.synchronize()
        }
        get {
            let storedValue = self.defaults.double(forKey: "BuildingHeight")
            if (storedValue > 0 && storedValue < 1) {
                return storedValue
            } else {
                return 0.35
            }
        }
    }
    
    var secsBetweenClears: Double {
        set(newValue) {
            self.defaults.set(newValue, forKey: "SecsBetweenClears")
            defaults.synchronize()
        }
        get {
            let storedValue = self.defaults.double(forKey: "SecsBetweenClears")
            if (storedValue > 0) {
                return storedValue
            } else {
                return 120
            }
        }
    }
}
