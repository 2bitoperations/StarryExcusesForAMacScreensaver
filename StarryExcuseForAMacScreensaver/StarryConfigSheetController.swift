
//
//  ConfigurationSheetManager.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 5/2/19.
//

import Foundation
import Cocoa
import os
import QuartzCore
import Metal

class StarryConfigSheetController : NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let defaultsManager = StarryDefaultsManager()
    weak var view: StarryExcuseForAView?
    private var log: OSLog?
    
    // Existing controls
    @IBOutlet weak var starsPerUpdate: NSTextField!
    @IBOutlet weak var buildingHeightSlider: NSSlider!
    @IBOutlet weak var buildingHeightPreview: NSTextField!
    @IBOutlet weak var secsBetweenClears: NSTextField!
    @IBOutlet weak var moonTraversalMinutes: NSTextField!
    
    // Building frequency controls
    @IBOutlet weak var buildingFrequencySlider: NSSlider!
    @IBOutlet weak var buildingFrequencyPreview: NSTextField!
    
    // Moon sizing (unified percentage) & brightness sliders
    @IBOutlet weak var moonSizePercentSlider: NSSlider!
    @IBOutlet weak var brightBrightnessSlider: NSSlider!
    @IBOutlet weak var darkBrightnessSlider: NSSlider!
    
    @IBOutlet weak var moonSizePercentPreview: NSTextField!
    @IBOutlet weak var brightBrightnessPreview: NSTextField!
    @IBOutlet weak var darkBrightnessPreview: NSTextField!
    
    // Phase override controls
    @IBOutlet weak var moonPhaseOverrideCheckbox: NSSwitch!
    @IBOutlet weak var moonPhaseSlider: NSSlider!
    @IBOutlet weak var moonPhasePreview: NSTextField!
    
    // Debug toggle
    @IBOutlet weak var showLightAreaTextureFillMaskCheckbox: NSSwitch!
    
    // Debug overlay toggle (NEW - no XIB update yet, thus optional)
    @IBOutlet weak var debugOverlayEnabledCheckbox: NSSwitch?
    
    // Shooting Stars controls
    @IBOutlet weak var shootingStarsEnabledCheckbox: NSSwitch!
    @IBOutlet weak var shootingStarsAvgSecondsField: NSTextField!
    @IBOutlet weak var shootingStarsDirectionPopup: NSPopUpButton!
    @IBOutlet weak var shootingStarsLengthSlider: NSSlider!
    @IBOutlet weak var shootingStarsSpeedSlider: NSSlider!
    @IBOutlet weak var shootingStarsThicknessSlider: NSSlider!
    @IBOutlet weak var shootingStarsBrightnessSlider: NSSlider!
    @IBOutlet weak var shootingStarsTrailDecaySlider: NSSlider!
    
    @IBOutlet weak var shootingStarsLengthPreview: NSTextField!
    @IBOutlet weak var shootingStarsSpeedPreview: NSTextField!
    @IBOutlet weak var shootingStarsThicknessPreview: NSTextField!
    @IBOutlet weak var shootingStarsBrightnessPreview: NSTextField!
    @IBOutlet weak var shootingStarsTrailDecayPreview: NSTextField!
    @IBOutlet weak var shootingStarsDebugSpawnBoundsCheckbox: NSSwitch!
    
    // Satellites controls (NEW - optional until XIB updated)
    @IBOutlet weak var satellitesEnabledCheckbox: NSSwitch?
    // Slider will represent satellites per minute (frequency). We convert to avg seconds.
    @IBOutlet weak var satellitesPerMinuteSlider: NSSlider?
    @IBOutlet weak var satellitesPerMinutePreview: NSTextField?
    @IBOutlet weak var satellitesSpeedSlider: NSSlider?
    @IBOutlet weak var satellitesSpeedPreview: NSTextField?
    @IBOutlet weak var satellitesSizeSlider: NSSlider?
    @IBOutlet weak var satellitesSizePreview: NSTextField?
    @IBOutlet weak var satellitesBrightnessSlider: NSSlider?
    @IBOutlet weak var satellitesBrightnessPreview: NSTextField?
    @IBOutlet weak var satellitesTrailingCheckbox: NSSwitch?
    @IBOutlet weak var satellitesTrailDecaySlider: NSSlider?
    @IBOutlet weak var satellitesTrailDecayPreview: NSTextField?
    
    // Preview container
    @IBOutlet weak var moonPreviewView: NSView!
    
    // Pause toggle
    @IBOutlet weak var pauseToggleButton: NSButton!
    
    // Save & Cancel
    @IBOutlet weak var saveCloseButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    
    // Preview engine (shared logic with saver)
    private var previewEngine: StarryEngine?
    private var previewTimer: Timer?
    
    // Metal preview (same renderer as screensaver)
    private var previewMetalLayer: CAMetalLayer?
    private var previewRenderer: StarryMetalRenderer?
    
    // Pause state
    private var isManuallyPaused = false
    private var isAutoPaused = false
    
    // Last-known values for change logging
    private var lastStarsPerUpdate: Int = 0
    private var lastBuildingHeight: Double = 0
    private var lastSecsBetweenClears: Double = 0
    private var lastMoonTraversalMinutes: Int = 0
    private var lastBuildingFrequency: Double = 0
    private var lastMoonSizePercent: Double = 0
    private var lastBrightBrightness: Double = 0
    private var lastDarkBrightness: Double = 0
    private var lastMoonPhaseOverrideEnabled: Bool = false
    private var lastMoonPhaseOverrideValue: Double = 0.0
    private var lastShowLightAreaTextureFillMask: Bool = false
    private var lastDebugOverlayEnabled: Bool = false
    
    // Shooting stars last-known
    private var lastShootingStarsEnabled: Bool = false
    private var lastShootingStarsAvgSeconds: Double = 0
    private var lastShootingStarsDirectionMode: Int = 0
    private var lastShootingStarsLength: Double = 0
    private var lastShootingStarsSpeed: Double = 0
    private var lastShootingStarsThickness: Double = 0
    private var lastShootingStarsBrightness: Double = 0
    private var lastShootingStarsTrailDecay: Double = 0
    private var lastShootingStarsDebugSpawnBounds: Bool = false
    
    // Satellites last-known (NEW)
    private var lastSatellitesEnabled: Bool = false
    private var lastSatellitesAvgSpawnSeconds: Double = 0
    private var lastSatellitesSpeed: Double = 0
    private var lastSatellitesSize: Double = 0
    private var lastSatellitesBrightness: Double = 0
    private var lastSatellitesTrailing: Bool = false
    private var lastSatellitesTrailDecay: Double = 0
    
    // MARK: - UI Actions (sliders / controls)
    
    @IBAction func buildingHeightChanged(_ sender: Any) {
        let oldVal = lastBuildingHeight
        let newVal = buildingHeightSlider.doubleValue
        buildingHeightPreview.stringValue = String(format: "%.3f", newVal)
        if oldVal != newVal {
            logChange(changedKey: "buildingHeight", oldValue: format(oldVal), newValue: format(newVal))
            lastBuildingHeight = newVal
        }
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        validateInputs()
        maybeClearAndRestartPreview(reason: "buildingHeightChanged")
    }
    
    @IBAction func buildingFrequencyChanged(_ sender: Any) {
        let newVal = buildingFrequencySlider.doubleValue
        if newVal != lastBuildingFrequency {
            logChange(changedKey: "buildingFrequency",
                      oldValue: format(lastBuildingFrequency),
                      newValue: format(newVal))
            lastBuildingFrequency = newVal
        }
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        validateInputs()
        maybeClearAndRestartPreview(reason: "buildingFrequencyChanged")
    }
    
    @IBAction func moonSliderChanged(_ sender: Any) {
        if sender as AnyObject === moonSizePercentSlider {
            let val = moonSizePercentSlider.doubleValue
            if val != lastMoonSizePercent {
                logChange(changedKey: "moonDiameterScreenWidthPercent",
                          oldValue: format(lastMoonSizePercent),
                          newValue: format(val))
                lastMoonSizePercent = val
            }
        }
        if brightBrightnessSlider.doubleValue != lastBrightBrightness {
            logChange(changedKey: "moonBrightBrightness",
                      oldValue: format(lastBrightBrightness),
                      newValue: format(brightBrightnessSlider.doubleValue))
            lastBrightBrightness = brightBrightnessSlider.doubleValue
        }
        if darkBrightnessSlider.doubleValue != lastDarkBrightness {
            logChange(changedKey: "moonDarkBrightness",
                      oldValue: format(lastDarkBrightness),
                      newValue: format(darkBrightnessSlider.doubleValue))
            lastDarkBrightness = darkBrightnessSlider.doubleValue
        }
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        validateInputs()
        maybeClearAndRestartPreview(reason: "moonControlsChanged")
    }
    
    @IBAction func moonPhaseOverrideToggled(_ sender: Any) {
        let enabled = moonPhaseOverrideCheckbox.state == .on
        if enabled != lastMoonPhaseOverrideEnabled {
            logChange(changedKey: "moonPhaseOverrideEnabled",
                      oldValue: lastMoonPhaseOverrideEnabled ? "true" : "false",
                      newValue: enabled ? "true" : "false")
            lastMoonPhaseOverrideEnabled = enabled
        }
        updatePhaseOverrideUIEnabled()
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        validateInputs()
        maybeClearAndRestartPreview(reason: "moonPhaseOverrideToggled")
    }
    
    @IBAction func moonPhaseSliderChanged(_ sender: Any) {
        let val = moonPhaseSlider.doubleValue
        moonPhasePreview.stringValue = formatPhase(val)
        if val != lastMoonPhaseOverrideValue {
            logChange(changedKey: "moonPhaseOverrideValue",
                      oldValue: format(lastMoonPhaseOverrideValue),
                      newValue: format(val))
            lastMoonPhaseOverrideValue = val
        }
        if moonPhaseOverrideCheckbox.state == .on {
            rebuildPreviewEngineIfNeeded()
            updatePreviewConfig()
            maybeClearAndRestartPreview(reason: "moonPhaseSliderChanged")
        }
    }
    
    @IBAction func showLightAreaTextureFillMaskToggled(_ sender: Any) {
        let newVal = (showLightAreaTextureFillMaskCheckbox.state == .on)
        if newVal != lastShowLightAreaTextureFillMask {
            logChange(changedKey: "showLightAreaTextureFillMask",
                      oldValue: lastShowLightAreaTextureFillMask ? "true" : "false",
                      newValue: newVal ? "true" : "false")
            lastShowLightAreaTextureFillMask = newVal
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        maybeClearAndRestartPreview(reason: "showLightAreaTextureFillMaskToggled")
    }
    
    @IBAction func debugOverlayToggled(_ sender: Any) {
        guard let checkbox = debugOverlayEnabledCheckbox else { return }
        let newVal = (checkbox.state == .on)
        if newVal != lastDebugOverlayEnabled {
            logChange(changedKey: "debugOverlayEnabled",
                      oldValue: lastDebugOverlayEnabled ? "true" : "false",
                      newValue: newVal ? "true" : "false")
            lastDebugOverlayEnabled = newVal
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    // MARK: - Shooting Stars Actions
    
    @IBAction func shootingStarsToggled(_ sender: Any) {
        let enabled = shootingStarsEnabledCheckbox.state == .on
        if enabled != lastShootingStarsEnabled {
            logChange(changedKey: "shootingStarsEnabled",
                      oldValue: lastShootingStarsEnabled ? "true" : "false",
                      newValue: enabled ? "true" : "false")
            lastShootingStarsEnabled = enabled
        }
        updateShootingStarsUIEnabled()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        maybeClearAndRestartPreview(reason: "shootingStarsToggled")
    }
    
    @IBAction func shootingStarsDirectionChanged(_ sender: Any) {
        let mode = shootingStarsDirectionPopup.indexOfSelectedItem
        if mode != lastShootingStarsDirectionMode {
            logChange(changedKey: "shootingStarsDirectionMode",
                      oldValue: "\(lastShootingStarsDirectionMode)",
                      newValue: "\(mode)")
            lastShootingStarsDirectionMode = mode
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    @IBAction func shootingStarsSliderChanged(_ sender: Any) {
        if shootingStarsLengthSlider.doubleValue != lastShootingStarsLength {
            logChange(changedKey: "shootingStarsLength",
                      oldValue: format(lastShootingStarsLength),
                      newValue: format(shootingStarsLengthSlider.doubleValue))
            lastShootingStarsLength = shootingStarsLengthSlider.doubleValue
        }
        if shootingStarsSpeedSlider.doubleValue != lastShootingStarsSpeed {
            logChange(changedKey: "shootingStarsSpeed",
                      oldValue: format(lastShootingStarsSpeed),
                      newValue: format(shootingStarsSpeedSlider.doubleValue))
            lastShootingStarsSpeed = shootingStarsSpeedSlider.doubleValue
        }
        if shootingStarsThicknessSlider.doubleValue != lastShootingStarsThickness {
            logChange(changedKey: "shootingStarsThickness",
                      oldValue: format(lastShootingStarsThickness),
                      newValue: format(shootingStarsThicknessSlider.doubleValue))
            lastShootingStarsThickness = shootingStarsThicknessSlider.doubleValue
        }
        if shootingStarsBrightnessSlider.doubleValue != lastShootingStarsBrightness {
            logChange(changedKey: "shootingStarsBrightness",
                      oldValue: format(lastShootingStarsBrightness),
                      newValue: format(shootingStarsBrightnessSlider.doubleValue))
            lastShootingStarsBrightness = shootingStarsBrightnessSlider.doubleValue
        }
        if shootingStarsTrailDecaySlider.doubleValue != lastShootingStarsTrailDecay {
            logChange(changedKey: "shootingStarsTrailDecay",
                      oldValue: format(lastShootingStarsTrailDecay),
                      newValue: format(shootingStarsTrailDecaySlider.doubleValue))
            lastShootingStarsTrailDecay = shootingStarsTrailDecaySlider.doubleValue
        }
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    @IBAction func shootingStarsAvgSecondsChanged(_ sender: Any) {
        let val = shootingStarsAvgSecondsField.doubleValue
        if val != lastShootingStarsAvgSeconds {
            logChange(changedKey: "shootingStarsAvgSeconds",
                      oldValue: format(lastShootingStarsAvgSeconds),
                      newValue: format(val))
            lastShootingStarsAvgSeconds = val
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    @IBAction func shootingStarsDebugSpawnBoundsToggled(_ sender: Any) {
        let newVal = shootingStarsDebugSpawnBoundsCheckbox.state == .on
        if newVal != lastShootingStarsDebugSpawnBounds {
            logChange(changedKey: "shootingStarsDebugSpawnBounds",
                      oldValue: lastShootingStarsDebugSpawnBounds ? "true" : "false",
                      newValue: newVal ? "true" : "false")
            lastShootingStarsDebugSpawnBounds = newVal
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    // MARK: - Satellites Actions (NEW)
    
    @IBAction func satellitesToggled(_ sender: Any) {
        guard let checkbox = satellitesEnabledCheckbox else { return }
        let enabled = (checkbox.state == .on)
        if enabled != lastSatellitesEnabled {
            logChange(changedKey: "satellitesEnabled",
                      oldValue: lastSatellitesEnabled ? "true" : "false",
                      newValue: enabled ? "true" : "false")
            lastSatellitesEnabled = enabled
        }
        updateSatellitesUIEnabled()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        maybeClearAndRestartPreview(reason: "satellitesToggled")
    }
    
    @IBAction func satellitesSliderChanged(_ sender: Any) {
        // Satellites per minute slider -> avg spawn seconds
        if let perMinSlider = satellitesPerMinuteSlider {
            let perMinute = max(0.1, perMinSlider.doubleValue)
            let avgSeconds = 60.0 / perMinute
            if avgSeconds != lastSatellitesAvgSpawnSeconds {
                logChange(changedKey: "satellitesAvgSpawnSeconds",
                          oldValue: format(lastSatellitesAvgSpawnSeconds),
                          newValue: format(avgSeconds))
                lastSatellitesAvgSpawnSeconds = avgSeconds
            }
        }
        if let speedSlider = satellitesSpeedSlider {
            if speedSlider.doubleValue != lastSatellitesSpeed {
                logChange(changedKey: "satellitesSpeed",
                          oldValue: format(lastSatellitesSpeed),
                          newValue: format(speedSlider.doubleValue))
                lastSatellitesSpeed = speedSlider.doubleValue
            }
        }
        if let sizeSlider = satellitesSizeSlider {
            if sizeSlider.doubleValue != lastSatellitesSize {
                logChange(changedKey: "satellitesSize",
                          oldValue: format(lastSatellitesSize),
                          newValue: format(sizeSlider.doubleValue))
                lastSatellitesSize = sizeSlider.doubleValue
            }
        }
        if let brightnessSlider = satellitesBrightnessSlider {
            if brightnessSlider.doubleValue != lastSatellitesBrightness {
                logChange(changedKey: "satellitesBrightness",
                          oldValue: format(lastSatellitesBrightness),
                          newValue: format(brightnessSlider.doubleValue))
                lastSatellitesBrightness = brightnessSlider.doubleValue
            }
        }
        if let trailDecaySlider = satellitesTrailDecaySlider {
            if trailDecaySlider.doubleValue != lastSatellitesTrailDecay {
                logChange(changedKey: "satellitesTrailDecay",
                          oldValue: format(lastSatellitesTrailDecay),
                          newValue: format(trailDecaySlider.doubleValue))
                lastSatellitesTrailDecay = trailDecaySlider.doubleValue
            }
        }
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    @IBAction func satellitesTrailingToggled(_ sender: Any) {
        guard let cb = satellitesTrailingCheckbox else { return }
        let enabled = cb.state == .on
        if enabled != lastSatellitesTrailing {
            logChange(changedKey: "satellitesTrailing",
                      oldValue: lastSatellitesTrailing ? "true" : "false",
                      newValue: enabled ? "true" : "false")
            lastSatellitesTrailing = enabled
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        maybeClearAndRestartPreview(reason: "satellitesTrailingToggled")
    }
    
    // MARK: - Preview Control Buttons
    
    @IBAction func previewTogglePause(_ sender: Any) {
        if isManuallyPaused || effectivePaused() {
            isManuallyPaused = false
            if !isAutoPaused {
                resumePreview(auto: false)
            }
            logChange(changedKey: "previewPauseState",
                      oldValue: "paused",
                      newValue: "running")
        } else {
            isManuallyPaused = true
            pausePreview(auto: false)
            logChange(changedKey: "previewPauseState",
                      oldValue: "running",
                      newValue: "paused")
        }
        updatePauseToggleTitle()
    }
    
    @IBAction func previewStep(_ sender: Any) {
        if !effectivePaused() {
            isManuallyPaused = true
            pausePreview(auto: false)
            logChange(changedKey: "previewPauseState",
                      oldValue: "running",
                      newValue: "paused(step)")
        }
        rebuildPreviewEngineIfNeeded()
        advancePreviewFrame()
        updatePauseToggleTitle()
    }
    
    @IBAction func previewClear(_ sender: Any) {
        logChange(changedKey: "previewClear", oldValue: "-", newValue: "requested")
        clearAndRestartPreview(force: true, reason: "manualClearButton")
    }
    
    // MARK: - Sheet lifecycle
    
    public func setView(view: StarryExcuseForAView) {
        self.view = view
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        window?.delegate = self
        styleWindow()
        
        // Load defaults into UI
        starsPerUpdate.integerValue = defaultsManager.starsPerUpdate
        buildingHeightSlider.doubleValue = defaultsManager.buildingHeight
        buildingHeightPreview.stringValue = String(format: "%.3f", defaultsManager.buildingHeight)
        secsBetweenClears.doubleValue = defaultsManager.secsBetweenClears
        moonTraversalMinutes.integerValue = defaultsManager.moonTraversalMinutes
        buildingFrequencySlider.doubleValue = defaultsManager.buildingFrequency
        buildingFrequencyPreview.stringValue = String(format: "%.3f", defaultsManager.buildingFrequency)
        
        moonSizePercentSlider.doubleValue = defaultsManager.moonDiameterScreenWidthPercent
        brightBrightnessSlider.doubleValue = defaultsManager.moonBrightBrightness
        darkBrightnessSlider.doubleValue = defaultsManager.moonDarkBrightness
        
        moonPhaseOverrideCheckbox.state = defaultsManager.moonPhaseOverrideEnabled ? .on : .off
        moonPhaseSlider.doubleValue = defaultsManager.moonPhaseOverrideValue
        moonPhasePreview.stringValue = formatPhase(moonPhaseSlider.doubleValue)
        updatePhaseOverrideUIEnabled()
        
        showLightAreaTextureFillMaskCheckbox.state = defaultsManager.showLightAreaTextureFillMask ? .on : .off
        debugOverlayEnabledCheckbox?.state = defaultsManager.debugOverlayEnabled ? .on : .off
        
        // Shooting stars
        shootingStarsEnabledCheckbox.state = defaultsManager.shootingStarsEnabled ? .on : .off
        shootingStarsAvgSecondsField.doubleValue = defaultsManager.shootingStarsAvgSeconds
        shootingStarsDirectionPopup.removeAllItems()
        shootingStarsDirectionPopup.addItems(withTitles: [
            "Random", "Left→Right", "Right→Left", "TL→BR", "TR→BL"
        ])
        shootingStarsDirectionPopup.selectItem(at: defaultsManager.shootingStarsDirectionMode)
        shootingStarsLengthSlider.doubleValue = defaultsManager.shootingStarsLength
        shootingStarsSpeedSlider.doubleValue = defaultsManager.shootingStarsSpeed
        shootingStarsThicknessSlider.doubleValue = defaultsManager.shootingStarsThickness
        shootingStarsBrightnessSlider.doubleValue = defaultsManager.shootingStarsBrightness
        shootingStarsTrailDecaySlider.doubleValue = defaultsManager.shootingStarsTrailDecay
        shootingStarsDebugSpawnBoundsCheckbox.state = defaultsManager.shootingStarsDebugShowSpawnBounds ? .on : .off
        
        // Satellites (NEW)
        if let satEnabled = satellitesEnabledCheckbox {
            satEnabled.state = defaultsManager.satellitesEnabled ? .on : .off
        }
        if let satPerMinSlider = satellitesPerMinuteSlider {
            // Convert avg seconds to per minute
            let perMinute = 60.0 / defaultsManager.satellitesAvgSpawnSeconds
            satPerMinSlider.doubleValue = perMinute
        }
        satellitesPerMinutePreview?.stringValue = satellitesPerMinuteSlider.map { String(format: "%.2f", $0.doubleValue) } ?? ""
        satellitesSpeedSlider?.doubleValue = defaultsManager.satellitesSpeed
        satellitesSpeedPreview?.stringValue = String(format: "%.0f", satellitesSpeedSlider?.doubleValue ?? 0)
        satellitesSizeSlider?.doubleValue = defaultsManager.satellitesSize
        satellitesSizePreview?.stringValue = String(format: "%.1f", satellitesSizeSlider?.doubleValue ?? 0)
        satellitesBrightnessSlider?.doubleValue = defaultsManager.satellitesBrightness
        satellitesBrightnessPreview?.stringValue = String(format: "%.2f", satellitesBrightnessSlider?.doubleValue ?? 0)
        satellitesTrailingCheckbox?.state = defaultsManager.satellitesTrailing ? .on : .off
        satellitesTrailDecaySlider?.doubleValue = defaultsManager.satellitesTrailDecay
        satellitesTrailDecayPreview?.stringValue = String(format: "%.3f", satellitesTrailDecaySlider?.doubleValue ?? 0)
        updateSatellitesUIEnabled()
        
        // Editable fields
        moonTraversalMinutes.isEditable = true
        moonTraversalMinutes.isSelectable = true
        moonTraversalMinutes.isEnabled = true
        
        shootingStarsAvgSecondsField.isEditable = true
        shootingStarsAvgSecondsField.isSelectable = true
        shootingStarsAvgSecondsField.isEnabled = (shootingStarsEnabledCheckbox.state == .on)
        
        // Snapshot last-known values
        lastStarsPerUpdate = starsPerUpdate.integerValue
        lastBuildingHeight = buildingHeightSlider.doubleValue
        lastSecsBetweenClears = secsBetweenClears.doubleValue
        lastMoonTraversalMinutes = moonTraversalMinutes.integerValue
        lastBuildingFrequency = buildingFrequencySlider.doubleValue
        lastMoonSizePercent = moonSizePercentSlider.doubleValue
        lastBrightBrightness = brightBrightnessSlider.doubleValue
        lastDarkBrightness = darkBrightnessSlider.doubleValue
        lastMoonPhaseOverrideEnabled = (moonPhaseOverrideCheckbox.state == .on)
        lastMoonPhaseOverrideValue = moonPhaseSlider.doubleValue
        lastShowLightAreaTextureFillMask = (showLightAreaTextureFillMaskCheckbox.state == .on)
        lastDebugOverlayEnabled = debugOverlayEnabledCheckbox?.state == .on
        
        lastShootingStarsEnabled = (shootingStarsEnabledCheckbox.state == .on)
        lastShootingStarsAvgSeconds = shootingStarsAvgSecondsField.doubleValue
        lastShootingStarsDirectionMode = shootingStarsDirectionPopup.indexOfSelectedItem
        lastShootingStarsLength = shootingStarsLengthSlider.doubleValue
        lastShootingStarsSpeed = shootingStarsSpeedSlider.doubleValue
        lastShootingStarsThickness = shootingStarsThicknessSlider.doubleValue
        lastShootingStarsBrightness = shootingStarsBrightnessSlider.doubleValue
        lastShootingStarsTrailDecay = shootingStarsTrailDecaySlider.doubleValue
        lastShootingStarsDebugSpawnBounds = (shootingStarsDebugSpawnBoundsCheckbox.state == .on)
        
        // Satellites last-known
        lastSatellitesEnabled = satellitesEnabledCheckbox?.state == .on
        lastSatellitesAvgSpawnSeconds = defaultsManager.satellitesAvgSpawnSeconds
        lastSatellitesSpeed = defaultsManager.satellitesSpeed
        lastSatellitesSize = defaultsManager.satellitesSize
        lastSatellitesBrightness = defaultsManager.satellitesBrightness
        lastSatellitesTrailing = defaultsManager.satellitesTrailing
        lastSatellitesTrailDecay = defaultsManager.satellitesTrailDecay
        
        // Delegates
        starsPerUpdate.delegate = self
        secsBetweenClears.delegate = self
        moonTraversalMinutes.delegate = self
        shootingStarsAvgSecondsField.delegate = self
        
        updatePreviewLabels()
        updateShootingStarsUIEnabled()
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        
        setupPreviewEngine()
        updatePauseToggleTitle()
        validateInputs()
        
        if let styleMaskRaw = window?.styleMask.rawValue {
            os_log("Config sheet loaded (styleMask raw=0x%{public}llx)", log: log!, type: .info, styleMaskRaw)
        } else {
            os_log("Config sheet loaded (no window style mask)", log: log!, type: .info)
        }
        
        applyAccessibility()
        applyButtonKeyEquivalents()
        applySystemSymbolImages()
    }
    
    // MARK: - Styling / Accessibility
    
    private func styleWindow() {
        guard let win = window else { return }
        win.title = "Starry Excuses Settings"
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .preference
        }
        win.isMovableByWindowBackground = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
    }
    
    private func applyButtonKeyEquivalents() {
        saveCloseButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
    }
    
    private func applyAccessibility() {
        starsPerUpdate.setAccessibilityLabel("Stars per update")
        buildingHeightSlider.setAccessibilityLabel("Maximum building height")
        buildingFrequencySlider.setAccessibilityLabel("Building frequency")
        secsBetweenClears.setAccessibilityLabel("Seconds between clears")
        moonTraversalMinutes.setAccessibilityLabel("Moon traversal minutes")
        moonSizePercentSlider.setAccessibilityLabel("Moon size as percent of screen width")
        brightBrightnessSlider.setAccessibilityLabel("Bright side brightness")
        darkBrightnessSlider.setAccessibilityLabel("Dark side brightness")
        moonPhaseOverrideCheckbox.setAccessibilityLabel("Lock moon phase")
        moonPhaseSlider.setAccessibilityLabel("Moon phase slider")
        showLightAreaTextureFillMaskCheckbox.setAccessibilityLabel("Show illuminated mask debug")
        debugOverlayEnabledCheckbox?.setAccessibilityLabel("Enable debug overlay (FPS / CPU / time)")
        shootingStarsEnabledCheckbox.setAccessibilityLabel("Enable shooting stars")
        shootingStarsAvgSecondsField.setAccessibilityLabel("Average seconds between shooting stars")
        shootingStarsDirectionPopup.setAccessibilityLabel("Shooting star direction mode")
        shootingStarsLengthSlider.setAccessibilityLabel("Shooting star length")
        shootingStarsSpeedSlider.setAccessibilityLabel("Shooting star speed")
        shootingStarsThicknessSlider.setAccessibilityLabel("Shooting star thickness")
        shootingStarsBrightnessSlider.setAccessibilityLabel("Shooting star brightness")
        shootingStarsTrailDecaySlider.setAccessibilityLabel("Shooting star trail decay (capped to ≤3s total fade)")
        shootingStarsDebugSpawnBoundsCheckbox.setAccessibilityLabel("Debug: show spawn bounds")
        pauseToggleButton.setAccessibilityLabel("Pause or resume preview")
        satellitesEnabledCheckbox?.setAccessibilityLabel("Enable satellites layer")
        satellitesPerMinuteSlider?.setAccessibilityLabel("Satellites per minute")
        satellitesSpeedSlider?.setAccessibilityLabel("Satellite speed")
        satellitesSizeSlider?.setAccessibilityLabel("Satellite size")
        satellitesBrightnessSlider?.setAccessibilityLabel("Satellite brightness")
        satellitesTrailingCheckbox?.setAccessibilityLabel("Satellite trailing effect")
        satellitesTrailDecaySlider?.setAccessibilityLabel("Satellite trail decay (capped to ≤3s total fade)")
    }
    
    // MARK: - SF Symbols injection
    
    private func applySystemSymbolImages() {
        guard #available(macOS 11.0, *) else { return }
        let symbolNames: Set<String> = [
            "sparkles",
            "arrow.clockwise",
            "clock",
            "building.2",
            "building.2.fill",
            "moonphase.new.moon",
            "moonphase.full.moon",
            "sun.min",
            "sun.max",
            "moon",
            "circle.lefthalf.filled",
            "timer",
            "location.north.line",
            "line.horizontal.3",
            "line.horizontal.3.decrease",
            "tortoise",
            "hare",
            "circle",
            "circle.fill",
            "cloud",
            "cloud.rain"
        ]
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .medium)
        if let root = window?.contentView {
            replaceSymbolImages(in: root, symbolNames: symbolNames, config: config)
        }
    }
    
    private func replaceSymbolImages(in view: NSView,
                                     symbolNames: Set<String>,
                                     config: NSImage.SymbolConfiguration) {
        for sub in view.subviews {
            if let iv = sub as? NSImageView {
                if let ident = iv.identifier?.rawValue, symbolNames.contains(ident) {
                    if let sym = NSImage(systemSymbolName: ident, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                        iv.image = sym
                        iv.contentTintColor = .labelColor
                    }
                } else if let name = iv.image?.name(), symbolNames.contains(name) {
                    if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                        iv.image = sym
                        iv.contentTintColor = .labelColor
                    }
                }
            }
            replaceSymbolImages(in: sub, symbolNames: symbolNames, config: config)
        }
    }
    
    // MARK: - Validation
    
    private func inputsAreValid() -> Bool {
        // For now all ranges enforced by slider min/max or property clamps.
        return true
    }
    
    private func validateInputs() {
        let valid = inputsAreValid()
        saveCloseButton.isEnabled = valid
        saveCloseButton.alphaValue = valid ? 1.0 : 0.5
    }
    
    // MARK: - NSTextFieldDelegate
    
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        handleTextFieldChange(field)
    }
    
    private func handleTextFieldChange(_ field: NSTextField) {
        if field == starsPerUpdate {
            let newVal = field.integerValue
            if newVal != lastStarsPerUpdate {
                logChange(changedKey: "starsPerUpdate",
                          oldValue: "\(lastStarsPerUpdate)",
                          newValue: "\(newVal)")
                lastStarsPerUpdate = newVal
                rebuildPreviewEngineIfNeeded()
                updatePreviewConfig()
            }
        } else if field == secsBetweenClears {
            let newVal = field.doubleValue
            if newVal != lastSecsBetweenClears {
                logChange(changedKey: "secsBetweenClears",
                          oldValue: format(lastSecsBetweenClears),
                          newValue: format(newVal))
                lastSecsBetweenClears = newVal
                rebuildPreviewEngineIfNeeded()
                updatePreviewConfig()
            }
        } else if field == moonTraversalMinutes {
            let newVal = field.integerValue
            if newVal != lastMoonTraversalMinutes {
                logChange(changedKey: "moonTraversalMinutes",
                          oldValue: "\(lastMoonTraversalMinutes)",
                          newValue: "\(newVal)")
                lastMoonTraversalMinutes = newVal
                rebuildPreviewEngineIfNeeded()
                updatePreviewConfig()
            }
        } else if field == shootingStarsAvgSeconds {
            shootingStarsAvgSecondsChanged(field)
        }
        validateInputs()
        maybeClearAndRestartPreview(reason: "textFieldChanged")
    }
    
    // MARK: - Window Delegate
    
    func windowDidResignKey(_ notification: Notification) {
        if !isManuallyPaused {
            pausePreview(auto: true)
            updatePauseToggleTitle()
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        if isAutoPaused && !isManuallyPaused {
            resumePreview(auto: true)
            updatePauseToggleTitle()
        }
    }
    
    // MARK: - Preview Engine Management (Metal)
    
    private func setupPreviewEngine() {
        guard let log = log else { return }
        let size = moonPreviewView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        
        // Ensure Metal layer attached to the preview container
        if previewMetalLayer == nil {
            moonPreviewView.wantsLayer = true
            let mLayer = CAMetalLayer()
            mLayer.frame = moonPreviewView.bounds
            // Set scale immediately to avoid invalid 0 drawable sizes
            let scale = moonPreviewView.window?.screen?.backingScaleFactor
                ?? moonPreviewView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            mLayer.contentsScale = scale
            moonPreviewView.layer?.addSublayer(mLayer)
            previewMetalLayer = mLayer
        }
        
        // Ensure renderer
        if previewRenderer == nil, let mLayer = previewMetalLayer {
            previewRenderer = StarryMetalRenderer(layer: mLayer, log: log)
            // Initialize drawable size if valid
            let scale = moonPreviewView.window?.screen?.backingScaleFactor
                ?? moonPreviewView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            let wPx = Int(round(size.width * scale))
            let hPx = Int(round(size.height * scale))
            if wPx > 0, hPx > 0 {
                previewRenderer?.updateDrawableSize(size: size, scale: scale)
            }
        }
        
        // Ensure engine
        previewEngine = StarryEngine(size: size,
                                     log: log,
                                     config: currentPreviewRuntimeConfig())
        if !isManuallyPaused && !isAutoPaused {
            startPreviewTimer()
        }
    }
    
    private func clearAndRestartPreview(force: Bool, reason: String) {
        guard let log = log else { return }
        stopPreviewTimer()
        previewEngine = nil
        os_log("Preview cleared (reason=%{public}@)", log: log, type: .info, reason)
        isManuallyPaused = false
        if previewEngine == nil {
            setupPreviewEngine()
        }
    }
    
    private func maybeClearAndRestartPreview(reason: String) {
        if inputsAreValid() {
            clearAndRestartPreview(force: true, reason: reason)
        }
    }
    
    private func rebuildPreviewEngineIfNeeded() {
        if previewEngine == nil { setupPreviewEngine() }
    }
    
    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.advancePreviewFrame()
        }
    }
    
    private func stopPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }
    
    private func pausePreview(auto: Bool) {
        stopPreviewTimer()
        if auto { isAutoPaused = true }
    }
    
    private func resumePreview(auto: Bool) {
        if auto { isAutoPaused = false }
        if !isManuallyPaused && previewTimer == nil {
            startPreviewTimer()
        }
    }
    
    private func advancePreviewFrame() {
        guard let engine = previewEngine,
              let renderer = previewRenderer,
              let mLayer = previewMetalLayer else { return }
        
        // Keep Metal layer in sync with view size
        let size = moonPreviewView.bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        engine.resizeIfNeeded(newSize: size)
        mLayer.frame = moonPreviewView.bounds
        
        // Use window's backingScaleFactor for crisp rendering
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let wPx = Int(round(size.width * scale))
        let hPx = Int(round(size.height * scale))
        guard wPx > 0, hPx > 0 else { return }
        renderer.updateDrawableSize(size: size, scale: scale)
        
        // Drive GPU path with the same engine as screensaver
        let drawData = engine.advanceFrameGPU()
        renderer.render(drawData: drawData)
    }
    
    private func currentPreviewRuntimeConfig() -> StarryRuntimeConfig {
        // Derive satellitesAvgSpawnSeconds from slider (per minute) if slider exists.
        var satellitesAvg: Double = defaultsManager.satellitesAvgSpawnSeconds
        if let slider = satellitesPerMinuteSlider {
            let perMinute = max(0.1, slider.doubleValue)
            satellitesAvg = 60.0 / perMinute
        }
        return StarryRuntimeConfig(
            starsPerUpdate: starsPerUpdate.integerValue,
            buildingHeight: buildingHeightSlider.doubleValue,
            buildingFrequency: buildingFrequencySlider.doubleValue,
            secsBetweenClears: secsBetweenClears.doubleValue,
            moonTraversalMinutes: moonTraversalMinutes.integerValue,
            moonDiameterScreenWidthPercent: moonSizePercentSlider.doubleValue,
            moonBrightBrightness: brightBrightnessSlider.doubleValue,
            moonDarkBrightness: darkBrightnessSlider.doubleValue,
            moonPhaseOverrideEnabled: moonPhaseOverrideCheckbox.state == .on,
            moonPhaseOverrideValue: moonPhaseSlider.doubleValue,
            traceEnabled: false,
            showLightAreaTextureFillMask: (showLightAreaTextureFillMaskCheckbox.state == .on),
            shootingStarsEnabled: (shootingStarsEnabledCheckbox.state == .on),
            shootingStarsAvgSeconds: shootingStarsAvgSecondsField.doubleValue,
            shootingStarsDirectionMode: shootingStarsDirectionPopup.indexOfSelectedItem,
            shootingStarsLength: shootingStarsLengthSlider.doubleValue,
            shootingStarsSpeed: shootingStarsSpeedSlider.doubleValue,
            shootingStarsThickness: shootingStarsThicknessSlider.doubleValue,
            shootingStarsBrightness: shootingStarsBrightnessSlider.doubleValue,
            shootingStarsTrailDecay: shootingStarsTrailDecaySlider.doubleValue,
            shootingStarsDebugShowSpawnBounds: (shootingStarsDebugSpawnBoundsCheckbox.state == .on),
            // Use optional map to preserve defaults when control not present.
            satellitesEnabled: satellitesEnabledCheckbox.map { $0.state == .on } ?? defaultsManager.satellitesEnabled,
            satellitesAvgSpawnSeconds: satellitesAvg,
            satellitesSpeed: satellitesSpeedSlider?.doubleValue ?? defaultsManager.satellitesSpeed,
            satellitesSize: satellitesSizeSlider?.doubleValue ?? defaultsManager.satellitesSize,
            satellitesBrightness: satellitesBrightnessSlider?.doubleValue ?? defaultsManager.satellitesBrightness,
            satellitesTrailing: satellitesTrailingCheckbox.map { $0.state == .on } ?? defaultsManager.satellitesTrailing,
            satellitesTrailDecay: satellitesTrailDecaySlider?.doubleValue ?? defaultsManager.satellitesTrailDecay,
            debugOverlayEnabled: debugOverlayEnabledCheckbox.map { $0.state == .on } ?? defaultsManager.debugOverlayEnabled
        )
    }
    
    private func updatePreviewConfig() {
        previewEngine?.updateConfig(currentPreviewRuntimeConfig())
    }
    
    private func updatePreviewLabels() {
        buildingFrequencyPreview?.stringValue = format(buildingFrequencySlider.doubleValue)
        let percent = moonSizePercentSlider.doubleValue * 100.0
        moonSizePercentPreview.stringValue = String(format: "%.2f%%", percent)
        brightBrightnessPreview.stringValue = String(format: "%.2f", brightBrightnessSlider.doubleValue)
        darkBrightnessPreview.stringValue = String(format: "%.2f", darkBrightnessSlider.doubleValue)
        moonPhasePreview?.stringValue = formatPhase(moonPhaseSlider.doubleValue)
        
        shootingStarsLengthPreview?.stringValue = "\(Int(shootingStarsLengthSlider.doubleValue))"
        shootingStarsSpeedPreview?.stringValue = "\(Int(shootingStarsSpeedSlider.doubleValue))"
        shootingStarsThicknessPreview?.stringValue = String(format: "%.0f", shootingStarsThicknessSlider.doubleValue)
        shootingStarsBrightnessPreview?.stringValue = String(format: "%.2f", shootingStarsBrightnessSlider.doubleValue)
        // Show that trails are capped to ≤ 3.0s fade
        shootingStarsTrailDecayPreview?.stringValue = String(format: "%.3f (≤ 3.0s fade)", shootingStarsTrailDecaySlider.doubleValue)
        
        if let satPerMinSlider = satellitesPerMinuteSlider {
            satellitesPerMinutePreview?.stringValue = String(format: "%.2f", satPerMinSlider.doubleValue)
        }
        if let speedSlider = satellitesSpeedSlider {
            satellitesSpeedPreview?.stringValue = String(format: "%.0f", speedSlider.doubleValue)
        }
        if let sizeSlider = satellitesSizeSlider {
            satellitesSizePreview?.stringValue = String(format: "%.1f", sizeSlider.doubleValue)
        }
        if let brightSlider = satellitesBrightnessSlider {
            satellitesBrightnessPreview?.stringValue = String(format: "%.2f", brightSlider.doubleValue)
        }
        if let trailDecaySlider = satellitesTrailDecaySlider {
            satellitesTrailDecayPreview?.stringValue = String(format: "%.3f (≤ 3.0s fade)", trailDecaySlider.doubleValue)
        }
    }
    
    private func effectivePaused() -> Bool {
        return previewTimer == nil
    }
    
    private func updatePauseToggleTitle() {
        let title = effectivePaused() ? "Resume" : "Pause"
        pauseToggleButton?.title = title
    }
    
    private func updatePhaseOverrideUIEnabled() {
        let enabled = moonPhaseOverrideCheckbox.state == .on
        moonPhaseSlider.isEnabled = enabled
        moonPhasePreview.isEnabled = enabled
        moonPhasePreview.alphaValue = enabled ? 1.0 : 0.5
    }
    
    private func updateShootingStarsUIEnabled() {
        let enabled = shootingStarsEnabledCheckbox.state == .on
        shootingStarsAvgSecondsField.isEnabled = enabled
        shootingStarsDirectionPopup.isEnabled = enabled
        shootingStarsLengthSlider.isEnabled = enabled
        shootingStarsSpeedSlider.isEnabled = enabled
        shootingStarsThicknessSlider.isEnabled = enabled
        shootingStarsBrightnessSlider.isEnabled = enabled
        shootingStarsTrailDecaySlider.isEnabled = enabled
        shootingStarsDebugSpawnBoundsCheckbox.isEnabled = enabled
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        shootingStarsAvgSecondsField.alphaValue = alpha
        shootingStarsDirectionPopup.alphaValue = alpha
        shootingStarsLengthSlider.alphaValue = alpha
        shootingStarsSpeedSlider.alphaValue = alpha
        shootingStarsThicknessSlider.alphaValue = alpha
        shootingStarsBrightnessSlider.alphaValue = alpha
        shootingStarsTrailDecaySlider.alphaValue = alpha
        shootingStarsDebugSpawnBoundsCheckbox.alphaValue = alpha
    }
    
    private func updateSatellitesUIEnabled() {
        guard let enabledCheckbox = satellitesEnabledCheckbox else { return }
        let enabled = enabledCheckbox.state == .on
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        satellitesPerMinuteSlider?.isEnabled = enabled
        satellitesSpeedSlider?.isEnabled = enabled
        satellitesSizeSlider?.isEnabled = enabled
        satellitesBrightnessSlider?.isEnabled = enabled
        satellitesTrailingCheckbox?.isEnabled = enabled
        satellitesTrailDecaySlider?.isEnabled = enabled && (satellitesTrailingCheckbox?.state == .on)
        satellitesPerMinuteSlider?.alphaValue = alpha
        satellitesPerMinutePreview?.alphaValue = alpha
        satellitesSpeedSlider?.alphaValue = alpha
        satellitesSpeedPreview?.alphaValue = alpha
        satellitesSizeSlider?.alphaValue = alpha
        satellitesSizePreview?.alphaValue = alpha
        satellitesBrightnessSlider?.alphaValue = alpha
        satellitesBrightnessPreview?.alphaValue = alpha
        satellitesTrailingCheckbox?.alphaValue = alpha
        satellitesTrailDecaySlider?.alphaValue = alpha
        satellitesTrailDecayPreview?.alphaValue = alpha
    }
    
    // MARK: - Save / Close / Cancel
    
    @IBAction func saveClose(_ sender: Any) {
        guard inputsAreValid() else {
            NSSound.beep()
            return
        }
        
        os_log("hit saveClose", log: self.log!, type: .info)
        
        defaultsManager.starsPerUpdate = starsPerUpdate.integerValue
        defaultsManager.buildingHeight = buildingHeightSlider.doubleValue
        defaultsManager.secsBetweenClears = secsBetweenClears.doubleValue
        defaultsManager.moonTraversalMinutes = moonTraversalMinutes.integerValue
        defaultsManager.buildingFrequency = buildingFrequencySlider.doubleValue
        defaultsManager.moonDiameterScreenWidthPercent = moonSizePercentSlider.doubleValue
        defaultsManager.moonBrightBrightness = brightBrightnessSlider.doubleValue
        defaultsManager.moonDarkBrightness = darkBrightnessSlider.doubleValue
        defaultsManager.moonPhaseOverrideEnabled = (moonPhaseOverrideCheckbox.state == .on)
        defaultsManager.moonPhaseOverrideValue = moonPhaseSlider.doubleValue
        defaultsManager.showLightAreaTextureFillMask = (showLightAreaTextureFillMaskCheckbox.state == .on)
        if let debugCB = debugOverlayEnabledCheckbox {
            defaultsManager.debugOverlayEnabled = (debugCB.state == .on)
        }
        
        // Shooting stars
        defaultsManager.shootingStarsEnabled = (shootingStarsEnabledCheckbox.state == .on)
        defaultsManager.shootingStarsAvgSeconds = shootingStarsAvgSecondsField.doubleValue
        defaultsManager.shootingStarsDirectionMode = shootingStarsDirectionPopup.indexOfSelectedItem
        defaultsManager.shootingStarsLength = shootingStarsLengthSlider.doubleValue
        defaultsManager.shootingStarsSpeed = shootingStarsSpeedSlider.doubleValue
        defaultsManager.shootingStarsThickness = shootingStarsThicknessSlider.doubleValue
        defaultsManager.shootingStarsBrightness = shootingStarsBrightnessSlider.doubleValue
        defaultsManager.shootingStarsTrailDecay = shootingStarsTrailDecaySlider.doubleValue
        defaultsManager.shootingStarsDebugShowSpawnBounds = (shootingStarsDebugSpawnBoundsCheckbox.state == .on)
        
        // Satellites
        if let cb = satellitesEnabledCheckbox {
            defaultsManager.satellitesEnabled = (cb.state == .on)
        }
        if let perMinSlider = satellitesPerMinuteSlider {
            let perMinute = max(0.1, perMinSlider.doubleValue)
            defaultsManager.satellitesAvgSpawnSeconds = 60.0 / perMinute
        }
        if let speedSlider = satellitesSpeedSlider {
            defaultsManager.satellitesSpeed = speedSlider.doubleValue
        }
        if let sizeSlider = satellitesSizeSlider {
            defaultsManager.satellitesSize = sizeSlider.doubleValue
        }
        if let brightnessSlider = satellitesBrightnessSlider {
            defaultsManager.satellitesBrightness = brightnessSlider.doubleValue
        }
        if let trailingCheckbox = satellitesTrailingCheckbox {
            defaultsManager.satellitesTrailing = (trailingCheckbox.state == .on)
        }
        if let trailDecaySlider = satellitesTrailDecaySlider {
            defaultsManager.satellitesTrailDecay = trailDecaySlider.doubleValue
        }
        
        view?.settingsChanged()
        
        window?.sheetParent?.endSheet(self.window!, returnCode: .OK)
        self.window?.close()
        
        os_log("exiting saveClose", log: self.log!, type: .info)
    }
    
    @IBAction func cancelClose(_ sender: Any) {
        os_log("cancelClose invoked - dismissing without persisting", log: self.log ?? OSLog.default, type: .info)
        window?.sheetParent?.endSheet(self.window!, returnCode: .cancel)
        self.window?.close()
    }
    
    deinit { stopPreviewTimer() }
    
    // MARK: - Logging Helpers
    
    private func logChange(changedKey: String, oldValue: String, newValue: String) {
        guard let log = log else { return }
        os_log("Config change %{public}@ : %{public}@ -> %{public}@ | state: %{public}@",
               log: log,
               type: .info,
               changedKey,
               oldValue,
               newValue,
               stateSummaryString())
    }
    
    // Refactored to avoid huge single expression that caused type-check slowdown.
    private func stateSummaryString() -> String {
        var parts: [String] = []
        parts.append("starsPerUpdate=\(starsPerUpdate.integerValue)")
        parts.append("buildingHeight=\(format(buildingHeightSlider.doubleValue))")
        parts.append("buildingFrequency=\(format(buildingFrequencySlider.doubleValue))")
        parts.append("secsBetweenClears=\(format(secsBetweenClears.doubleValue))")
        parts.append("moonTraversalMinutes=\(moonTraversalMinutes.integerValue)")
        parts.append("moonSizePercent=\(format(moonSizePercentSlider.doubleValue))")
        parts.append("moonBrightBrightness=\(format(brightBrightnessSlider.doubleValue))")
        parts.append("moonDarkBrightness=\(format(darkBrightnessSlider.doubleValue))")
        parts.append("moonPhaseOverrideEnabled=\(moonPhaseOverrideCheckbox.state == .on)")
        parts.append("moonPhaseOverrideValue=\(format(moonPhaseSlider.doubleValue))")
        parts.append("showLightAreaTextureFillMask=\(showLightAreaTextureFillMaskCheckbox.state == .on)")
        let debugEnabled: Bool = {
            if let cb = debugOverlayEnabledCheckbox {
                return cb.state == .on
            } else {
                return defaultsManager.debugOverlayEnabled
            }
        }()
        parts.append("debugOverlayEnabled=\(debugEnabled)")
        parts.append("shootingStarsEnabled=\(shootingStarsEnabledCheckbox.state == .on)")
        parts.append("shootingStarsAvgSeconds=\(format(shootingStarsAvgSecondsField.doubleValue))")
        parts.append("shootingStarsDirectionMode=\(shootingStarsDirectionPopup.indexOfSelectedItem)")
        parts.append("shootingStarsLength=\(format(shootingStarsLengthSlider.doubleValue))")
        parts.append("shootingStarsSpeed=\(format(shootingStarsSpeedSlider.doubleValue))")
        parts.append("shootingStarsThickness=\(format(shootingStarsThicknessSlider.doubleValue))")
        parts.append("shootingStarsBrightness=\(format(shootingStarsBrightnessSlider.doubleValue))")
        parts.append("shootingStarsTrailDecay=\(format(shootingStarsTrailDecaySlider.doubleValue))")
        parts.append("shootingStarsDebugSpawnBounds=\(shootingStarsDebugSpawnBoundsCheckbox.state == .on)")
        if let satellitesEnabledCheckbox {
            parts.append("satellitesEnabled=\(satellitesEnabledCheckbox.state == .on)")
        } else {
            parts.append("satellitesEnabled=nil")
        }
        parts.append("satellitesAvgSpawnSeconds=\(format(lastSatellitesAvgSpawnSeconds))")
        parts.append("satellitesSpeed=\(format(lastSatellitesSpeed))")
        parts.append("satellitesSize=\(format(lastSatellitesSize))")
        parts.append("satellitesBrightness=\(format(lastSatellitesBrightness))")
        parts.append("satellitesTrailing=\(lastSatellitesTrailing)")
        parts.append("satellitesTrailDecay=\(format(lastSatellitesTrailDecay))")
        return parts.joined(separator: ", ")
    }
    
    private func format(_ d: Double) -> String {
        String(format: "%.3f", d)
    }
    
    private func formatPhase(_ d: Double) -> String {
        String(format: "%.3f", d)
    }
}
