import Foundation
import Cocoa
import os
import QuartzCore
import Metal

class StarryConfigSheetController : NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let defaultsManager = StarryDefaultsManager()
    weak var view: StarryExcuseForAView?
    private var log: OSLog?
    
    // General section (authoritative stars-per-second)  (present in XIB)
    @IBOutlet weak var starsPerSecond: NSTextField!
    
    // Present in XIB
    @IBOutlet weak var buildingLightsPerSecond: NSTextField!
    
    // The following formerly IUO outlets may be absent in the currently simplified XIB.
    // Make them optional and guard all usage.
    @IBOutlet weak var buildingHeightSlider: NSSlider?
    @IBOutlet weak var buildingHeightPreview: NSTextField?
    @IBOutlet weak var secsBetweenClears: NSTextField?
    @IBOutlet weak var moonTraversalMinutes: NSTextField?
    
    // Building frequency controls
    @IBOutlet weak var buildingFrequencySlider: NSSlider?
    @IBOutlet weak var buildingFrequencyPreview: NSTextField?
    
    // Moon sizing & brightness sliders
    @IBOutlet weak var moonSizePercentSlider: NSSlider!          // present in XIB
    @IBOutlet weak var brightBrightnessSlider: NSSlider?
    @IBOutlet weak var darkBrightnessSlider: NSSlider?
    
    @IBOutlet weak var moonSizePercentPreview: NSTextField!      // present in XIB
    @IBOutlet weak var brightBrightnessPreview: NSTextField?
    @IBOutlet weak var darkBrightnessPreview: NSTextField?
    
    // Phase override controls
    @IBOutlet weak var moonPhaseOverrideCheckbox: NSSwitch?
    @IBOutlet weak var moonPhaseSlider: NSSlider?
    @IBOutlet weak var moonPhasePreview: NSTextField?
    
    // Debug toggle
    @IBOutlet weak var showLightAreaTextureFillMaskCheckbox: NSSwitch?
    
    // Debug overlay toggle
    @IBOutlet weak var debugOverlayEnabledCheckbox: NSSwitch?
    
    // Shooting Stars controls (only enabled checkbox + avg seconds field exist in XIB)
    @IBOutlet weak var shootingStarsEnabledCheckbox: NSSwitch!
    @IBOutlet weak var shootingStarsAvgSecondsField: NSTextField!
    @IBOutlet weak var shootingStarsDirectionPopup: NSPopUpButton?
    @IBOutlet weak var shootingStarsLengthSlider: NSSlider?
    @IBOutlet weak var shootingStarsSpeedSlider: NSSlider?
    @IBOutlet weak var shootingStarsThicknessSlider: NSSlider?
    @IBOutlet weak var shootingStarsBrightnessSlider: NSSlider?
    @IBOutlet weak var shootingStarsTrailDecaySlider: NSSlider?
    var shootingStarsTrailHalfLifeSlider: NSSlider? { shootingStarsTrailDecaySlider }
    
    @IBOutlet weak var shootingStarsLengthPreview: NSTextField?
    @IBOutlet weak var shootingStarsSpeedPreview: NSTextField?
    @IBOutlet weak var shootingStarsThicknessPreview: NSTextField?
    @IBOutlet weak var shootingStarsBrightnessPreview: NSTextField?
    @IBOutlet weak var shootingStarsTrailDecayPreview: NSTextField?
    var shootingStarsTrailHalfLifePreview: NSTextField? { shootingStarsTrailDecayPreview }
    @IBOutlet weak var shootingStarsDebugSpawnBoundsCheckbox: NSSwitch?
    
    // Satellites controls (only enable checkbox + avg seconds field exist in XIB)
    @IBOutlet weak var satellitesEnabledCheckbox: NSSwitch?
    @IBOutlet weak var satellitesAvgSecondsField: NSTextField?
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
    var satellitesTrailHalfLifeSlider: NSSlider? { satellitesTrailDecaySlider }
    var satellitesTrailHalfLifePreview: NSTextField? { satellitesTrailDecayPreview }
    
    // Preview container (present in XIB)
    @IBOutlet weak var moonPreviewView: NSView!
    
    // Pause toggle (present)
    @IBOutlet weak var pauseToggleButton: NSButton!
    
    // Save & Cancel (present)
    @IBOutlet weak var saveCloseButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    
    // Preview engine
    private var previewEngine: StarryEngine?
    private var previewTimer: Timer?
    
    // Metal preview
    private var previewMetalLayer: CAMetalLayer?
    private var previewRenderer: StarryMetalRenderer?
    
    // Pause state
    private var isManuallyPaused = false
    private var isAutoPaused = false
    
    // Last-known values
    private var lastStarsPerSecond: Int = 0
    private var lastBuildingLightsPerSecond: Double = 0
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
    private var lastShootingStarsTrailHalfLifeSeconds: Double = 0
    private var lastShootingStarsDebugSpawnBounds: Bool = false
    
    // Satellites last-known
    private var lastSatellitesEnabled: Bool = false
    private var lastSatellitesAvgSpawnSeconds: Double = 0
    private var lastSatellitesSpeed: Double = 0
    private var lastSatellitesSize: Double = 0
    private var lastSatellitesBrightness: Double = 0
    private var lastSatellitesTrailing: Bool = false
    private var lastSatellitesTrailHalfLifeSeconds: Double = 0
    
    // MARK: - UI Actions
    
    @IBAction func buildingHeightChanged(_ sender: Any) {
        guard let slider = buildingHeightSlider else { return }
        let oldVal = lastBuildingHeight
        let newVal = slider.doubleValue
        buildingHeightPreview?.stringValue = String(format: "%.3f", newVal)
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
        guard let slider = buildingFrequencySlider else { return }
        let newVal = slider.doubleValue
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
        if let bright = brightBrightnessSlider, bright.doubleValue != lastBrightBrightness {
            logChange(changedKey: "moonBrightBrightness",
                      oldValue: format(lastBrightBrightness),
                      newValue: format(bright.doubleValue))
            lastBrightBrightness = bright.doubleValue
        }
        if let dark = darkBrightnessSlider, dark.doubleValue != lastDarkBrightness {
            logChange(changedKey: "moonDarkBrightness",
                      oldValue: format(lastDarkBrightness),
                      newValue: format(dark.doubleValue))
            lastDarkBrightness = dark.doubleValue
        }
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        validateInputs()
        maybeClearAndRestartPreview(reason: "moonControlsChanged")
    }
    
    @IBAction func moonPhaseOverrideToggled(_ sender: Any) {
        guard let checkbox = moonPhaseOverrideCheckbox else { return }
        let enabled = checkbox.state == .on
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
        guard let slider = moonPhaseSlider else { return }
        let val = slider.doubleValue
        moonPhasePreview?.stringValue = formatPhase(val)
        if val != lastMoonPhaseOverrideValue {
            logChange(changedKey: "moonPhaseOverrideValue",
                      oldValue: format(lastMoonPhaseOverrideValue),
                      newValue: format(val))
            lastMoonPhaseOverrideValue = val
        }
        if moonPhaseOverrideCheckbox?.state == .on {
            rebuildPreviewEngineIfNeeded()
            updatePreviewConfig()
            maybeClearAndRestartPreview(reason: "moonPhaseSliderChanged")
        }
    }
    
    @IBAction func showLightAreaTextureFillMaskToggled(_ sender: Any) {
        guard let cb = showLightAreaTextureFillMaskCheckbox else { return }
        let newVal = (cb.state == .on)
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
        previewRenderer?.setDebugOverlayEnabled(newVal)
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
        guard let popup = shootingStarsDirectionPopup else { return }
        let mode = popup.indexOfSelectedItem
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
        if let length = shootingStarsLengthSlider, length.doubleValue != lastShootingStarsLength {
            logChange(changedKey: "shootingStarsLength",
                      oldValue: format(lastShootingStarsLength),
                      newValue: format(length.doubleValue))
            lastShootingStarsLength = length.doubleValue
        }
        if let speed = shootingStarsSpeedSlider, speed.doubleValue != lastShootingStarsSpeed {
            logChange(changedKey: "shootingStarsSpeed",
                      oldValue: format(lastShootingStarsSpeed),
                      newValue: format(speed.doubleValue))
            lastShootingStarsSpeed = speed.doubleValue
        }
        if let thick = shootingStarsThicknessSlider, thick.doubleValue != lastShootingStarsThickness {
            logChange(changedKey: "shootingStarsThickness",
                      oldValue: format(lastShootingStarsThickness),
                      newValue: format(thick.doubleValue))
            lastShootingStarsThickness = thick.doubleValue
        }
        if let bright = shootingStarsBrightnessSlider, bright.doubleValue != lastShootingStarsBrightness {
            logChange(changedKey: "shootingStarsBrightness",
                      oldValue: format(lastShootingStarsBrightness),
                      newValue: format(bright.doubleValue))
            lastShootingStarsBrightness = bright.doubleValue
        }
        if let hlSlider = shootingStarsTrailHalfLifeSlider, hlSlider.doubleValue != lastShootingStarsTrailHalfLifeSeconds {
            logChange(changedKey: "shootingStarsTrailHalfLifeSeconds",
                      oldValue: format(lastShootingStarsTrailHalfLifeSeconds),
                      newValue: format(hlSlider.doubleValue))
            lastShootingStarsTrailHalfLifeSeconds = hlSlider.doubleValue
            updateRendererHalfLives()
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
        guard let cb = shootingStarsDebugSpawnBoundsCheckbox else { return }
        let newVal = cb.state == .on
        if newVal != lastShootingStarsDebugSpawnBounds {
            logChange(changedKey: "shootingStarsDebugSpawnBounds",
                      oldValue: lastShootingStarsDebugSpawnBounds ? "true" : "false",
                      newValue: newVal ? "true" : "false")
            lastShootingStarsDebugSpawnBounds = newVal
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    // MARK: - Satellites Actions
    
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
        if let speedSlider = satellitesSpeedSlider, speedSlider.doubleValue != lastSatellitesSpeed {
            logChange(changedKey: "satellitesSpeed",
                      oldValue: format(lastSatellitesSpeed),
                      newValue: format(speedSlider.doubleValue))
            lastSatellitesSpeed = speedSlider.doubleValue
        }
        if let sizeSlider = satellitesSizeSlider, sizeSlider.doubleValue != lastSatellitesSize {
            logChange(changedKey: "satellitesSize",
                      oldValue: format(lastSatellitesSize),
                      newValue: format(sizeSlider.doubleValue))
            lastSatellitesSize = sizeSlider.doubleValue
        }
        if let brightnessSlider = satellitesBrightnessSlider, brightnessSlider.doubleValue != lastSatellitesBrightness {
            logChange(changedKey: "satellitesBrightness",
                      oldValue: format(lastSatellitesBrightness),
                      newValue: format(brightnessSlider.doubleValue))
            lastSatellitesBrightness = brightnessSlider.doubleValue
        }
        if let trailHalfLifeSlider = satellitesTrailHalfLifeSlider {
            let secsHL = trailHalfLifeSlider.doubleValue
            if secsHL != lastSatellitesTrailHalfLifeSeconds {
                logChange(changedKey: "satellitesTrailHalfLifeSeconds",
                          oldValue: format(lastSatellitesTrailHalfLifeSeconds),
                          newValue: format(secsHL))
                lastSatellitesTrailHalfLifeSeconds = secsHL
                updateRendererHalfLives()
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
    
    @IBAction func satellitesAvgSecondsChanged(_ sender: Any) {
        guard let field = satellitesAvgSecondsField else { return }
        let val = field.doubleValue
        if val != lastSatellitesAvgSpawnSeconds {
            logChange(changedKey: "satellitesAvgSpawnSeconds",
                      oldValue: format(lastSatellitesAvgSpawnSeconds),
                      newValue: format(val))
            lastSatellitesAvgSpawnSeconds = val
        }
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
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
        
        // Set log early so logChange is safe later in setup
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        
        // Load defaults into UI (stars-per-second authoritative)
        starsPerSecond.integerValue = Int(round(defaultsManager.starsPerSecond))
        buildingLightsPerSecond.doubleValue = defaultsManager.buildingLightsPerSecond
        
        if let slider = buildingHeightSlider {
            slider.doubleValue = defaultsManager.buildingHeight
            buildingHeightPreview?.stringValue = String(format: "%.3f", defaultsManager.buildingHeight)
        }
        if let sbc = secsBetweenClears {
            sbc.doubleValue = defaultsManager.secsBetweenClears
        }
        if let mtm = moonTraversalMinutes {
            mtm.integerValue = defaultsManager.moonTraversalMinutes
        }
        if let bf = buildingFrequencySlider {
            bf.doubleValue = defaultsManager.buildingFrequency
            buildingFrequencyPreview?.stringValue = String(format: "%.3f", defaultsManager.buildingFrequency)
        }
        
        moonSizePercentSlider.doubleValue = defaultsManager.moonDiameterScreenWidthPercent
        if let bright = brightBrightnessSlider { bright.doubleValue = defaultsManager.moonBrightBrightness }
        if let dark = darkBrightnessSlider { dark.doubleValue = defaultsManager.moonDarkBrightness }
        
        if let overrideCB = moonPhaseOverrideCheckbox {
            overrideCB.state = defaultsManager.moonPhaseOverrideEnabled ? .on : .off
        }
        if let phaseSlider = moonPhaseSlider {
            phaseSlider.doubleValue = defaultsManager.moonPhaseOverrideValue
            moonPhasePreview?.stringValue = formatPhase(phaseSlider.doubleValue)
        }
        updatePhaseOverrideUIEnabled()
        
        showLightAreaTextureFillMaskCheckbox?.state = defaultsManager.showLightAreaTextureFillMask ? .on : .off
        debugOverlayEnabledCheckbox?.state = defaultsManager.debugOverlayEnabled ? .on : .off
        
        // Shooting stars (available controls only)
        shootingStarsEnabledCheckbox.state = defaultsManager.shootingStarsEnabled ? .on : .off
        shootingStarsAvgSecondsField.doubleValue = defaultsManager.shootingStarsAvgSeconds
        shootingStarsDirectionPopup?.removeAllItems()
        shootingStarsDirectionPopup?.addItems(withTitles: [
            "Random", "Left→Right", "Right→Left", "TL→BR", "TR→BL"
        ])
        if let popup = shootingStarsDirectionPopup {
            popup.selectItem(at: min(max(0, defaultsManager.shootingStarsDirectionMode), popup.numberOfItems - 1))
        }
        shootingStarsLengthSlider?.doubleValue = defaultsManager.shootingStarsLength
        shootingStarsSpeedSlider?.doubleValue = defaultsManager.shootingStarsSpeed
        shootingStarsThicknessSlider?.doubleValue = defaultsManager.shootingStarsThickness
        shootingStarsBrightnessSlider?.doubleValue = defaultsManager.shootingStarsBrightness
        if let trail = shootingStarsTrailHalfLifeSlider {
            trail.minValue = 0.01
            trail.maxValue = 2.0
            trail.doubleValue = defaultsManager.shootingStarsTrailHalfLifeSeconds
        }
        shootingStarsDebugSpawnBoundsCheckbox?.state = defaultsManager.shootingStarsDebugShowSpawnBounds ? .on : .off
        
        // Satellites
        satellitesEnabledCheckbox?.state = defaultsManager.satellitesEnabled ? .on : .off
        satellitesAvgSecondsField?.doubleValue = defaultsManager.satellitesAvgSpawnSeconds
        if let satPerMinSlider = satellitesPerMinuteSlider {
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
        if let trailSlider = satellitesTrailHalfLifeSlider {
            trailSlider.minValue = 0.01
            trailSlider.maxValue = 2.0
            trailSlider.doubleValue = defaultsManager.satellitesTrailHalfLifeSeconds
        }
        satellitesTrailHalfLifePreview?.stringValue = String(format: "%.3f s", satellitesTrailHalfLifeSlider?.doubleValue ?? defaultsManager.satellitesTrailHalfLifeSeconds)
        updateSatellitesUIEnabled()
        
        // Editable fields (only those present)
        moonTraversalMinutes?.isEditable = true
        moonTraversalMinutes?.isSelectable = true
        moonTraversalMinutes?.isEnabled = true
        shootingStarsAvgSecondsField.isEditable = true
        shootingStarsAvgSecondsField.isSelectable = true
        shootingStarsAvgSecondsField.isEnabled = (shootingStarsEnabledCheckbox.state == .on)
        starsPerSecond.isEditable = true
        starsPerSecond.isSelectable = true
        starsPerSecond.isEnabled = true
        satellitesAvgSecondsField?.isEditable = true
        satellitesAvgSecondsField?.isSelectable = true
        satellitesAvgSecondsField?.isEnabled = satellitesEnabledCheckbox?.state == .on
        
        // Snapshot last-known (use defaults when control missing)
        lastStarsPerSecond = starsPerSecond.integerValue
        lastBuildingLightsPerSecond = buildingLightsPerSecond.doubleValue
        lastBuildingHeight = buildingHeightSlider?.doubleValue ?? defaultsManager.buildingHeight
        lastSecsBetweenClears = secsBetweenClears?.doubleValue ?? defaultsManager.secsBetweenClears
        lastMoonTraversalMinutes = moonTraversalMinutes?.integerValue ?? defaultsManager.moonTraversalMinutes
        lastBuildingFrequency = buildingFrequencySlider?.doubleValue ?? defaultsManager.buildingFrequency
        lastMoonSizePercent = moonSizePercentSlider.doubleValue
        lastBrightBrightness = brightBrightnessSlider?.doubleValue ?? defaultsManager.moonBrightBrightness
        lastDarkBrightness = darkBrightnessSlider?.doubleValue ?? defaultsManager.moonDarkBrightness
        lastMoonPhaseOverrideEnabled = moonPhaseOverrideCheckbox?.state == .on
        lastMoonPhaseOverrideValue = moonPhaseSlider?.doubleValue ?? defaultsManager.moonPhaseOverrideValue
        lastShowLightAreaTextureFillMask = showLightAreaTextureFillMaskCheckbox?.state == .on
        lastDebugOverlayEnabled = debugOverlayEnabledCheckbox?.state == .on
        
        lastShootingStarsEnabled = (shootingStarsEnabledCheckbox.state == .on)
        lastShootingStarsAvgSeconds = shootingStarsAvgSecondsField.doubleValue
        lastShootingStarsDirectionMode = shootingStarsDirectionPopup?.indexOfSelectedItem ?? defaultsManager.shootingStarsDirectionMode
        lastShootingStarsLength = shootingStarsLengthSlider?.doubleValue ?? defaultsManager.shootingStarsLength
        lastShootingStarsSpeed = shootingStarsSpeedSlider?.doubleValue ?? defaultsManager.shootingStarsSpeed
        lastShootingStarsThickness = shootingStarsThicknessSlider?.doubleValue ?? defaultsManager.shootingStarsThickness
        lastShootingStarsBrightness = shootingStarsBrightnessSlider?.doubleValue ?? defaultsManager.shootingStarsBrightness
        lastShootingStarsTrailHalfLifeSeconds = shootingStarsTrailHalfLifeSlider?.doubleValue ?? defaultsManager.shootingStarsTrailHalfLifeSeconds
        lastShootingStarsDebugSpawnBounds = shootingStarsDebugSpawnBoundsCheckbox?.state == .on
        
        lastSatellitesEnabled = satellitesEnabledCheckbox?.state == .on ?? defaultsManager.satellitesEnabled
        lastSatellitesAvgSpawnSeconds = satellitesAvgSecondsField?.doubleValue ?? defaultsManager.satellitesAvgSpawnSeconds
        lastSatellitesSpeed = satellitesSpeedSlider?.doubleValue ?? defaultsManager.satellitesSpeed
        lastSatellitesSize = satellitesSizeSlider?.doubleValue ?? defaultsManager.satellitesSize
        lastSatellitesBrightness = satellitesBrightnessSlider?.doubleValue ?? defaultsManager.satellitesBrightness
        lastSatellitesTrailing = satellitesTrailingCheckbox?.state == .on ?? defaultsManager.satellitesTrailing
        lastSatellitesTrailHalfLifeSeconds = satellitesTrailHalfLifeSlider?.doubleValue ?? defaultsManager.satellitesTrailHalfLifeSeconds
        
        // Delegates
        starsPerSecond.delegate = self
        buildingLightsPerSecond.delegate = self
        secsBetweenClears?.delegate = self
        moonTraversalMinutes?.delegate = self
        shootingStarsAvgSecondsField.delegate = self
        satellitesAvgSecondsField?.delegate = self
        
        updatePreviewLabels()
        updateShootingStarsUIEnabled()
        
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
        
        if let renderer = previewRenderer {
            renderer.setDebugOverlayEnabled(lastDebugOverlayEnabled)
        }
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
        starsPerSecond.setAccessibilityLabel("Stars per second")
        buildingLightsPerSecond.setAccessibilityLabel("Building lights per second")
        buildingHeightSlider?.setAccessibilityLabel("Maximum building height")
        buildingFrequencySlider?.setAccessibilityLabel("Building frequency")
        secsBetweenClears?.setAccessibilityLabel("Seconds between clears")
        moonTraversalMinutes?.setAccessibilityLabel("Moon traversal minutes")
        moonSizePercentSlider.setAccessibilityLabel("Moon size as percent of screen width")
        brightBrightnessSlider?.setAccessibilityLabel("Bright side brightness")
        darkBrightnessSlider?.setAccessibilityLabel("Dark side brightness")
        moonPhaseOverrideCheckbox?.setAccessibilityLabel("Lock moon phase")
        moonPhaseSlider?.setAccessibilityLabel("Moon phase slider")
        showLightAreaTextureFillMaskCheckbox?.setAccessibilityLabel("Show illuminated mask debug")
        debugOverlayEnabledCheckbox?.setAccessibilityLabel("Enable debug overlay (FPS / CPU / time)")
        shootingStarsEnabledCheckbox.setAccessibilityLabel("Enable shooting stars")
        shootingStarsAvgSecondsField.setAccessibilityLabel("Average seconds between shooting stars")
        shootingStarsDirectionPopup?.setAccessibilityLabel("Shooting star direction mode")
        shootingStarsLengthSlider?.setAccessibilityLabel("Shooting star length")
        shootingStarsSpeedSlider?.setAccessibilityLabel("Shooting star speed")
        shootingStarsThicknessSlider?.setAccessibilityLabel("Shooting star thickness")
        shootingStarsBrightnessSlider?.setAccessibilityLabel("Shooting star brightness")
        shootingStarsTrailHalfLifeSlider?.setAccessibilityLabel("Shooting star trail half-life (0.01–2.0 s)")
        shootingStarsDebugSpawnBoundsCheckbox?.setAccessibilityLabel("Debug: show spawn bounds")
        pauseToggleButton.setAccessibilityLabel("Pause or resume preview")
        satellitesEnabledCheckbox?.setAccessibilityLabel("Enable satellites layer")
        satellitesAvgSecondsField?.setAccessibilityLabel("Average seconds between satellites")
        satellitesPerMinuteSlider?.setAccessibilityLabel("Satellites per minute")
        satellitesSpeedSlider?.setAccessibilityLabel("Satellite speed")
        satellitesSizeSlider?.setAccessibilityLabel("Satellite size")
        satellitesBrightnessSlider?.setAccessibilityLabel("Satellite brightness")
        satellitesTrailingCheckbox?.setAccessibilityLabel("Satellite trailing effect")
        satellitesTrailHalfLifeSlider?.setAccessibilityLabel("Satellite trail half-life (0.01–2.0 s)")
    }
    
    // MARK: - SF Symbols
    
    private func applySystemSymbolImages() {
        guard #available(macOS 11.0, *) else { return }
        let symbolNames: Set<String> = [
            "sparkles","arrow.clockwise","clock","building.2","building.2.fill",
            "moonphase.new.moon","moonphase.full.moon","sun.min","sun.max","moon",
            "circle.lefthalf.filled","timer","location.north.line","line.horizontal.3",
            "line.horizontal.3.decrease","tortoise","hare","circle","circle.fill",
            "cloud","cloud.rain"
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
    
    private func inputsAreValid() -> Bool { true }
    
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
        if field == starsPerSecond {
            let newVal = max(0, field.integerValue)
            if newVal != lastStarsPerSecond {
                logChange(changedKey: "starsPerSecond",
                          oldValue: "\(lastStarsPerSecond)",
                          newValue: "\(newVal)")
                lastStarsPerSecond = newVal
                rebuildPreviewEngineIfNeeded()
                updatePreviewConfig()
            }
        } else if field == buildingLightsPerSecond {
            let newVal = field.doubleValue
            if newVal != lastBuildingLightsPerSecond {
                logChange(changedKey: "buildingLightsPerSecond",
                          oldValue: format(lastBuildingLightsPerSecond),
                          newValue: format(newVal))
                lastBuildingLightsPerSecond = newVal
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
        } else if field == shootingStarsAvgSecondsField {
            shootingStarsAvgSecondsChanged(field)
        } else if field == satellitesAvgSecondsField {
            satellitesAvgSecondsChanged(field)
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
    
    // MARK: - Preview Engine Management
    
    private func setupPreviewEngine() {
        guard let log = log else { return }
        let size = moonPreviewView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        
        if previewMetalLayer == nil {
            moonPreviewView.wantsLayer = true
            let mLayer = CAMetalLayer()
            mLayer.frame = moonPreviewView.bounds
            let scale = moonPreviewView.window?.screen?.backingScaleFactor
                ?? moonPreviewView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            mLayer.contentsScale = scale
            moonPreviewView.layer?.addSublayer(mLayer)
            previewMetalLayer = mLayer
        }
        
        if previewRenderer == nil, let mLayer = previewMetalLayer {
            previewRenderer = StarryMetalRenderer(layer: mLayer, log: log)
            let scale = moonPreviewView.window?.screen?.backingScaleFactor
                ?? moonPreviewView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            previewRenderer?.updateDrawableSize(size: size, scale: scale)
            updateRendererHalfLives()
            previewRenderer?.setDebugOverlayEnabled(lastDebugOverlayEnabled)
        }
        
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
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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
        
        let size = moonPreviewView.bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        engine.resizeIfNeeded(newSize: size)
        mLayer.frame = moonPreviewView.bounds
        
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let wPx = Int(round(size.width * scale))
        let hPx = Int(round(size.height * scale))
        guard wPx > 0, hPx > 0 else { return }
        renderer.updateDrawableSize(size: size, scale: scale)
        
        let drawData = engine.advanceFrameGPU()
        renderer.render(drawData: drawData)
    }
    
    private func currentPreviewRuntimeConfig() -> StarryRuntimeConfig {
        // Satellites avg spawn seconds (choose explicit field or derived per-minute slider)
        var satellitesAvg: Double
        if let secsField = satellitesAvgSecondsField {
            satellitesAvg = secsField.doubleValue
        } else if let slider = satellitesPerMinuteSlider {
            let perMinute = max(0.1, slider.doubleValue)
            satellitesAvg = 60.0 / perMinute
        } else {
            satellitesAvg = defaultsManager.satellitesAvgSpawnSeconds
        }
        
        let starsPerSec = Double(starsPerSecond.integerValue)
        let derivedLegacyStarsPerUpdate = max(0, Int(round(starsPerSec / 10.0)))
        
        return StarryRuntimeConfig(
            starsPerUpdate: derivedLegacyStarsPerUpdate,
            buildingHeight: buildingHeightSlider?.doubleValue ?? lastBuildingHeight,
            buildingFrequency: buildingFrequencySlider?.doubleValue ?? lastBuildingFrequency,
            secsBetweenClears: secsBetweenClears?.doubleValue ?? lastSecsBetweenClears,
            moonTraversalMinutes: moonTraversalMinutes?.integerValue ?? lastMoonTraversalMinutes,
            moonDiameterScreenWidthPercent: moonSizePercentSlider.doubleValue,
            moonBrightBrightness: brightBrightnessSlider?.doubleValue ?? lastBrightBrightness,
            moonDarkBrightness: darkBrightnessSlider?.doubleValue ?? lastDarkBrightness,
            moonPhaseOverrideEnabled: moonPhaseOverrideCheckbox?.state == .on ? true : lastMoonPhaseOverrideEnabled,
            moonPhaseOverrideValue: moonPhaseSlider?.doubleValue ?? lastMoonPhaseOverrideValue,
            traceEnabled: false,
            showLightAreaTextureFillMask: showLightAreaTextureFillMaskCheckbox?.state == .on ? true : lastShowLightAreaTextureFillMask,
            shootingStarsEnabled: shootingStarsEnabledCheckbox.state == .on,
            shootingStarsAvgSeconds: shootingStarsAvgSecondsField.doubleValue,
            shootingStarsDirectionMode: shootingStarsDirectionPopup?.indexOfSelectedItem ?? lastShootingStarsDirectionMode,
            shootingStarsLength: shootingStarsLengthSlider?.doubleValue ?? lastShootingStarsLength,
            shootingStarsSpeed: shootingStarsSpeedSlider?.doubleValue ?? lastShootingStarsSpeed,
            shootingStarsThickness: shootingStarsThicknessSlider?.doubleValue ?? lastShootingStarsThickness,
            shootingStarsBrightness: shootingStarsBrightnessSlider?.doubleValue ?? lastShootingStarsBrightness,
            shootingStarsDebugShowSpawnBounds: shootingStarsDebugSpawnBoundsCheckbox?.state == .on ?? lastShootingStarsDebugSpawnBounds,
            satellitesEnabled: satellitesEnabledCheckbox?.state == .on ?? lastSatellitesEnabled,
            satellitesAvgSpawnSeconds: satellitesAvg,
            satellitesSpeed: satellitesSpeedSlider?.doubleValue ?? lastSatellitesSpeed,
            satellitesSize: satellitesSizeSlider?.doubleValue ?? lastSatellitesSize,
            satellitesBrightness: satellitesBrightnessSlider?.doubleValue ?? lastSatellitesBrightness,
            satellitesTrailing: satellitesTrailingCheckbox?.state == .on ?? lastSatellitesTrailing,
            debugOverlayEnabled: debugOverlayEnabledCheckbox?.state == .on ?? lastDebugOverlayEnabled,
            debugDropBaseEveryNFrames: 0,
            debugForceClearEveryNFrames: 0,
            debugLogEveryFrame: false,
            buildingLightsPerUpdate: defaultsManager.buildingLightsPerUpdate,
            disableFlasherOnBase: false,
            starsPerSecond: starsPerSec,
            buildingLightsPerSecond: buildingLightsPerSecond.doubleValue
        )
    }
    
    private func updatePreviewConfig() {
        previewEngine?.updateConfig(currentPreviewRuntimeConfig())
        updateRendererHalfLives()
        if let renderer = previewRenderer {
            renderer.setDebugOverlayEnabled(lastDebugOverlayEnabled)
        }
    }
    
    private func updateRendererHalfLives() {
        let shootingHL = shootingStarsTrailHalfLifeSlider?.doubleValue ?? defaultsManager.shootingStarsTrailHalfLifeSeconds
        let satellitesHL = satellitesTrailHalfLifeSlider?.doubleValue ?? defaultsManager.satellitesTrailHalfLifeSeconds
        previewRenderer?.setTrailHalfLives(satellites: satellitesHL, shooting: shootingHL)
    }
    
    private func updatePreviewLabels() {
        buildingFrequencyPreview?.stringValue = format(buildingFrequencySlider?.doubleValue ?? lastBuildingFrequency)
        let percent = moonSizePercentSlider.doubleValue * 100.0
        moonSizePercentPreview.stringValue = String(format: "%.2f%%", percent)
        brightBrightnessPreview?.stringValue = String(format: "%.2f", brightBrightnessSlider?.doubleValue ?? lastBrightBrightness)
        darkBrightnessPreview?.stringValue = String(format: "%.2f", darkBrightnessSlider?.doubleValue ?? lastDarkBrightness)
        moonPhasePreview?.stringValue = formatPhase(moonPhaseSlider?.doubleValue ?? lastMoonPhaseOverrideValue)
        
        if let length = shootingStarsLengthSlider {
            shootingStarsLengthPreview?.stringValue = "\(Int(length.doubleValue))"
        }
        if let speed = shootingStarsSpeedSlider {
            shootingStarsSpeedPreview?.stringValue = "\(Int(speed.doubleValue))"
        }
        if let thick = shootingStarsThicknessSlider {
            shootingStarsThicknessPreview?.stringValue = String(format: "%.0f", thick.doubleValue)
        }
        if let bright = shootingStarsBrightnessSlider {
            shootingStarsBrightnessPreview?.stringValue = String(format: "%.2f", bright.doubleValue)
        }
        if let hl = shootingStarsTrailHalfLifeSlider {
            shootingStarsTrailHalfLifePreview?.stringValue = String(format: "HL: %.3f s", hl.doubleValue)
        }
        
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
        if let trailHalfLifeSlider = satellitesTrailHalfLifeSlider {
            satellitesTrailHalfLifePreview?.stringValue = String(format: "HL: %.3f s", trailHalfLifeSlider.doubleValue)
        }
    }
    
    private func effectivePaused() -> Bool { previewTimer == nil }
    
    private func updatePauseToggleTitle() {
        pauseToggleButton?.title = effectivePaused() ? "Resume" : "Pause"
    }
    
    private func updatePhaseOverrideUIEnabled() {
        let enabled = moonPhaseOverrideCheckbox?.state == .on
        moonPhaseSlider?.isEnabled = enabled
        if let mp = moonPhasePreview {
            mp.isEnabled = enabled
            mp.alphaValue = enabled ? 1.0 : 0.5
        }
    }
    
    private func updateShootingStarsUIEnabled() {
        let enabled = shootingStarsEnabledCheckbox.state == .on
        shootingStarsAvgSecondsField.isEnabled = enabled
        shootingStarsDirectionPopup?.isEnabled = enabled
        shootingStarsLengthSlider?.isEnabled = enabled
        shootingStarsSpeedSlider?.isEnabled = enabled
        shootingStarsThicknessSlider?.isEnabled = enabled
        shootingStarsBrightnessSlider?.isEnabled = enabled
        shootingStarsTrailHalfLifeSlider?.isEnabled = enabled
        shootingStarsDebugSpawnBoundsCheckbox?.isEnabled = enabled
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        shootingStarsAvgSecondsField.alphaValue = alpha
        shootingStarsDirectionPopup?.alphaValue = alpha
        shootingStarsLengthSlider?.alphaValue = alpha
        shootingStarsSpeedSlider?.alphaValue = alpha
        shootingStarsThicknessSlider?.alphaValue = alpha
        shootingStarsBrightnessSlider?.alphaValue = alpha
        shootingStarsTrailHalfLifeSlider?.alphaValue = alpha
        shootingStarsDebugSpawnBoundsCheckbox?.alphaValue = alpha
    }
    
    private func updateSatellitesUIEnabled() {
        guard let enabledCheckbox = satellitesEnabledCheckbox else { return }
        let enabled = enabledCheckbox.state == .on
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        satellitesAvgSecondsField?.isEnabled = enabled
        satellitesAvgSecondsField?.alphaValue = alpha
        satellitesPerMinuteSlider?.isEnabled = enabled
        satellitesSpeedSlider?.isEnabled = enabled
        satellitesSizeSlider?.isEnabled = enabled
        satellitesBrightnessSlider?.isEnabled = enabled
        satellitesTrailingCheckbox?.isEnabled = enabled
        satellitesTrailHalfLifeSlider?.isEnabled = enabled && (satellitesTrailingCheckbox?.state == .on)
        satellitesPerMinuteSlider?.alphaValue = alpha
        satellitesPerMinutePreview?.alphaValue = alpha
        satellitesSpeedSlider?.alphaValue = alpha
        satellitesSpeedPreview?.alphaValue = alpha
        satellitesSizeSlider?.alphaValue = alpha
        satellitesSizePreview?.alphaValue = alpha
        satellitesBrightnessSlider?.alphaValue = alpha
        satellitesBrightnessPreview?.alphaValue = alpha
        satellitesTrailingCheckbox?.alphaValue = alpha
        satellitesTrailHalfLifeSlider?.alphaValue = alpha
        satellitesTrailHalfLifePreview?.alphaValue = alpha
    }
    
    // MARK: - Save / Close / Cancel
    
    @IBAction func saveClose(_ sender: Any) {
        guard inputsAreValid() else {
            NSSound.beep()
            return
        }
        
        os_log("hit saveClose", log: self.log!, type: .info)
        
        // Persist new authoritative stars-per-second
        defaultsManager.starsPerSecond = Double(starsPerSecond.integerValue)
        defaultsManager.buildingLightsPerSecond = buildingLightsPerSecond.doubleValue
        if let slider = buildingHeightSlider { defaultsManager.buildingHeight = slider.doubleValue }
        if let sbc = secsBetweenClears { defaultsManager.secsBetweenClears = sbc.doubleValue }
        if let mtm = moonTraversalMinutes { defaultsManager.moonTraversalMinutes = mtm.integerValue }
        if let bf = buildingFrequencySlider { defaultsManager.buildingFrequency = bf.doubleValue }
        defaultsManager.moonDiameterScreenWidthPercent = moonSizePercentSlider.doubleValue
        if let bright = brightBrightnessSlider { defaultsManager.moonBrightBrightness = bright.doubleValue }
        if let dark = darkBrightnessSlider { defaultsManager.moonDarkBrightness = dark.doubleValue }
        if let cb = moonPhaseOverrideCheckbox { defaultsManager.moonPhaseOverrideEnabled = (cb.state == .on) }
        if let phaseSlider = moonPhaseSlider { defaultsManager.moonPhaseOverrideValue = phaseSlider.doubleValue }
        if let cb = showLightAreaTextureFillMaskCheckbox { defaultsManager.showLightAreaTextureFillMask = (cb.state == .on) }
        if let debugCB = debugOverlayEnabledCheckbox {
            defaultsManager.debugOverlayEnabled = (debugCB.state == .on)
        }
        
        defaultsManager.shootingStarsEnabled = (shootingStarsEnabledCheckbox.state == .on)
        defaultsManager.shootingStarsAvgSeconds = shootingStarsAvgSecondsField.doubleValue
        if let popup = shootingStarsDirectionPopup {
            defaultsManager.shootingStarsDirectionMode = popup.indexOfSelectedItem
        }
        if let length = shootingStarsLengthSlider { defaultsManager.shootingStarsLength = length.doubleValue }
        if let speed = shootingStarsSpeedSlider { defaultsManager.shootingStarsSpeed = speed.doubleValue }
        if let thick = shootingStarsThicknessSlider { defaultsManager.shootingStarsThickness = thick.doubleValue }
        if let bright = shootingStarsBrightnessSlider { defaultsManager.shootingStarsBrightness = bright.doubleValue }
        if let hl = shootingStarsTrailHalfLifeSlider { defaultsManager.shootingStarsTrailHalfLifeSeconds = hl.doubleValue }
        if let spawn = shootingStarsDebugSpawnBoundsCheckbox { defaultsManager.shootingStarsDebugShowSpawnBounds = (spawn.state == .on) }
        
        if let cb = satellitesEnabledCheckbox {
            defaultsManager.satellitesEnabled = (cb.state == .on)
        }
        if let secsField = satellitesAvgSecondsField {
            defaultsManager.satellitesAvgSpawnSeconds = secsField.doubleValue
        } else if let perMinSlider = satellitesPerMinuteSlider {
            let perMinute = max(0.1, perMinSlider.doubleValue)
            defaultsManager.satellitesAvgSpawnSeconds = 60.0 / perMinute
        }
        if let speedSlider = satellitesSpeedSlider { defaultsManager.satellitesSpeed = speedSlider.doubleValue }
        if let sizeSlider = satellitesSizeSlider { defaultsManager.satellitesSize = sizeSlider.doubleValue }
        if let brightnessSlider = satellitesBrightnessSlider { defaultsManager.satellitesBrightness = brightnessSlider.doubleValue }
        if let trailingCheckbox = satellitesTrailingCheckbox { defaultsManager.satellitesTrailing = (trailingCheckbox.state == .on) }
        if let trailHalfLifeSlider = satellitesTrailHalfLifeSlider { defaultsManager.satellitesTrailHalfLifeSeconds = trailHalfLifeSlider.doubleValue }
        
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
    
    private func stateSummaryString() -> String {
        var parts: [String] = []
        parts.append("starsPerSecond=\(starsPerSecond.integerValue)")
        parts.append("buildingLightsPerSecond=\(format(buildingLightsPerSecond.doubleValue))")
        parts.append("buildingHeight=\(format(buildingHeightSlider?.doubleValue ?? lastBuildingHeight))")
        parts.append("buildingFrequency=\(format(buildingFrequencySlider?.doubleValue ?? lastBuildingFrequency))")
        parts.append("secsBetweenClears=\(format(secsBetweenClears?.doubleValue ?? lastSecsBetweenClears))")
        parts.append("moonTraversalMinutes=\(moonTraversalMinutes?.integerValue ?? lastMoonTraversalMinutes)")
        parts.append("moonSizePercent=\(format(moonSizePercentSlider.doubleValue))")
        parts.append("moonBrightBrightness=\(format(brightBrightnessSlider?.doubleValue ?? lastBrightBrightness))")
        parts.append("moonDarkBrightness=\(format(darkBrightnessSlider?.doubleValue ?? lastDarkBrightness))")
        parts.append("moonPhaseOverrideEnabled=\(moonPhaseOverrideCheckbox?.state == .on ? "true":"false")")
        parts.append("moonPhaseOverrideValue=\(format(moonPhaseSlider?.doubleValue ?? lastMoonPhaseOverrideValue))")
        parts.append("showLightAreaTextureFillMask=\(showLightAreaTextureFillMaskCheckbox?.state == .on ? "true" : "false")")
        let debugEnabled: Bool = debugOverlayEnabledCheckbox?.state == .on
        parts.append("debugOverlayEnabled=\(debugEnabled)")
        parts.append("shootingStarsEnabled=\(shootingStarsEnabledCheckbox.state == .on)")
        parts.append("shootingStarsAvgSeconds=\(format(shootingStarsAvgSecondsField.doubleValue))")
        parts.append("shootingStarsDirectionMode=\(shootingStarsDirectionPopup?.indexOfSelectedItem ?? lastShootingStarsDirectionMode)")
        parts.append("shootingStarsLength=\(format(shootingStarsLengthSlider?.doubleValue ?? lastShootingStarsLength))")
        parts.append("shootingStarsSpeed=\(format(shootingStarsSpeedSlider?.doubleValue ?? lastShootingStarsSpeed))")
        parts.append("shootingStarsThickness=\(format(shootingStarsThicknessSlider?.doubleValue ?? lastShootingStarsThickness))")
        parts.append("shootingStarsBrightness=\(format(shootingStarsBrightnessSlider?.doubleValue ?? lastShootingStarsBrightness))")
        parts.append("shootingStarsTrailHalfLifeSeconds=\(format(shootingStarsTrailHalfLifeSlider?.doubleValue ?? lastShootingStarsTrailHalfLifeSeconds))")
        parts.append("shootingStarsDebugSpawnBounds=\(shootingStarsDebugSpawnBoundsCheckbox?.state == .on ? "true":"false")")
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
        parts.append("satellitesTrailHalfLifeSeconds=\(format(lastSatellitesTrailHalfLifeSeconds))")
        return parts.joined(separator: ", ")
    }
    
    private func format(_ d: Double) -> String { String(format: "%.3f", d) }
    private func formatPhase(_ d: Double) -> String { String(format: "%.3f", d) }
}
