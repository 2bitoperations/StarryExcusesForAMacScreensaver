//
//  ConfigurationSheetManager.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 5/2/19.
//  Copyright © 2019 Andrew Malota. All rights reserved.
//

import Foundation
import Cocoa
import os

class StarryConfigSheetController : NSWindowController {
    let defaultsManager = StarryDefaultsManager()
    weak var view: StarryExcuseForAView?
    private var log: OSLog?
    
    // Existing
    @IBOutlet weak var starsPerUpdate: NSTextField!
    @IBOutlet weak var buildingHeightSlider: NSSlider!
    @IBOutlet weak var buildingHeightPreview: NSTextField!
    @IBOutlet weak var secsBetweenClears: NSTextField!
    @IBOutlet weak var moonTraversalMinutes: NSTextField!
    
    // New moon sizing & brightness sliders
    @IBOutlet weak var minMoonRadiusSlider: NSSlider!
    @IBOutlet weak var maxMoonRadiusSlider: NSSlider!
    @IBOutlet weak var brightBrightnessSlider: NSSlider!
    @IBOutlet weak var darkBrightnessSlider: NSSlider!
    
    @IBOutlet weak var minMoonRadiusPreview: NSTextField!
    @IBOutlet weak var maxMoonRadiusPreview: NSTextField!
    @IBOutlet weak var brightBrightnessPreview: NSTextField!
    @IBOutlet weak var darkBrightnessPreview: NSTextField!
    
    // Preview view
    @IBOutlet weak var moonPreviewView: MoonPreviewView!
    
    @IBAction func buildingHeightChanged(_ sender: Any) {
        buildingHeightPreview.stringValue = String(format: "%.3f", buildingHeightSlider.doubleValue)
        updateMoonPreview()
    }
    
    @IBAction func moonSliderChanged(_ sender: Any) {
        // Clamp logical relationship live
        if Int(minMoonRadiusSlider.integerValue) > Int(maxMoonRadiusSlider.integerValue) {
            maxMoonRadiusSlider.integerValue = minMoonRadiusSlider.integerValue
        }
        updatePreviewLabels()
        updateMoonPreview()
    }
    
    public func setView(view: StarryExcuseForAView) {
        self.view = view
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        starsPerUpdate.integerValue = defaultsManager.starsPerUpdate
        buildingHeightSlider.doubleValue = defaultsManager.buildingHeight
        buildingHeightPreview.stringValue = String(format: "%.3f", defaultsManager.buildingHeight)
        secsBetweenClears.doubleValue = defaultsManager.secsBetweenClears
        moonTraversalMinutes.integerValue = defaultsManager.moonTraversalMinutes
        
        minMoonRadiusSlider.integerValue = defaultsManager.moonMinRadius
        maxMoonRadiusSlider.integerValue = defaultsManager.moonMaxRadius
        brightBrightnessSlider.doubleValue = defaultsManager.moonBrightBrightness
        darkBrightnessSlider.doubleValue = defaultsManager.moonDarkBrightness
        
        updatePreviewLabels()
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        
        configurePreview()
    }
    
    private func configurePreview() {
        moonPreviewView.configure(
            phaseFraction: currentPhaseFraction(),
            waxing: currentWaxing(),
            minRadius: minMoonRadiusSlider.integerValue,
            maxRadius: maxMoonRadiusSlider.integerValue,
            brightBrightness: brightBrightnessSlider.doubleValue,
            darkBrightness: darkBrightnessSlider.doubleValue,
            traversalMinutes: moonTraversalMinutes.integerValue,
            buildingHeightFraction: buildingHeightSlider.doubleValue
        )
        moonPreviewView.needsDisplay = true
    }
    
    private func currentPhaseFraction() -> Double {
        // Mirror Moon.computePhase via a tiny helper (midnight Austin)
        let tz = TimeZone(identifier: "America/Chicago")!
        var comps = Calendar(identifier: .gregorian).dateComponents(in: tz, from: Date())
        comps.hour = 0; comps.minute = 0; comps.second = 0; comps.nanosecond = 0
        let date = Calendar(identifier: .gregorian).date(from: comps) ?? Date()
        let synodic = 29.530588853
        let jd = 2440587.5 + date.timeIntervalSince1970 / 86400.0
        // epoch 2000-01-06 18:14 UTC
        var epochComps = DateComponents()
        epochComps.year = 2000; epochComps.month = 1; epochComps.day = 6
        epochComps.hour = 18; epochComps.minute = 14; epochComps.timeZone = TimeZone(secondsFromGMT: 0)
        let epoch = Calendar(identifier: .gregorian).date(from: epochComps)!
        let epochJD = 2440587.5 + epoch.timeIntervalSince1970 / 86400.0
        let days = jd - epochJD
        var age = days.truncatingRemainder(dividingBy: synodic)
        if age < 0 { age += synodic }
        let fraction = 0.5 * (1 - cos(2 * Double.pi * (age / synodic)))
        return min(max(fraction, 0.0), 1.0)
    }
    
    private func currentWaxing() -> Bool {
        let fraction = currentPhaseFraction()
        return fraction <= 0.5
    }
    
    private func updatePreviewLabels() {
        minMoonRadiusPreview.stringValue = "\(minMoonRadiusSlider.integerValue)"
        maxMoonRadiusPreview.stringValue = "\(maxMoonRadiusSlider.integerValue)"
        brightBrightnessPreview.stringValue = String(format: "%.2f", brightBrightnessSlider.doubleValue)
        darkBrightnessPreview.stringValue = String(format: "%.2f", darkBrightnessSlider.doubleValue)
    }
    
    private func updateMoonPreview() {
        configurePreview()
    }
    
    @IBAction func saveClose(_ sender: Any) {
        os_log("hit saveClose", log: self.log!, type: .info)
        
        defaultsManager.starsPerUpdate = starsPerUpdate.integerValue
        defaultsManager.buildingHeight = buildingHeightSlider.doubleValue
        defaultsManager.secsBetweenClears = secsBetweenClears.doubleValue
        defaultsManager.moonTraversalMinutes = moonTraversalMinutes.integerValue
        defaultsManager.moonMinRadius = minMoonRadiusSlider.integerValue
        defaultsManager.moonMaxRadius = maxMoonRadiusSlider.integerValue
        defaultsManager.moonBrightBrightness = brightBrightnessSlider.doubleValue
        defaultsManager.moonDarkBrightness = darkBrightnessSlider.doubleValue
        defaultsManager.normalizeMoonRadiusBounds()
        
        view?.settingsChanged()
        
        window!.sheetParent?.endSheet(self.window!, returnCode: NSApplication.ModalResponse.OK)
        self.window!.close()
        
        os_log("exiting saveClose", log: self.log!, type: .info)
    }
}
