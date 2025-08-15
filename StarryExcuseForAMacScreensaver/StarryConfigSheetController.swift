//
//  ConfigurationSheetManager.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 5/2/19.
//

import Foundation
import Cocoa
import os

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
    
    // Moon sizing & brightness sliders
    @IBOutlet weak var minMoonRadiusSlider: NSSlider!
    @IBOutlet weak var maxMoonRadiusSlider: NSSlider!
    @IBOutlet weak var brightBrightnessSlider: NSSlider!
    @IBOutlet weak var darkBrightnessSlider: NSSlider!
    
    @IBOutlet weak var minMoonRadiusPreview: NSTextField!
    @IBOutlet weak var maxMoonRadiusPreview: NSTextField!
    @IBOutlet weak var brightBrightnessPreview: NSTextField!
    @IBOutlet weak var darkBrightnessPreview: NSTextField!
    
    // Phase override controls (modern toggle)
    @IBOutlet weak var moonPhaseOverrideCheckbox: NSSwitch!
    @IBOutlet weak var moonPhaseSlider: NSSlider!
    @IBOutlet weak var moonPhasePreview: NSTextField!
    
    // Debug / troubleshooting: show illuminated texture fill mask (modern toggle)
    @IBOutlet weak var showLightAreaTextureFillMaskCheckbox: NSSwitch!
    
    // Shooting Stars controls (Option Set C) including modern toggles
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
    
    // Preview container (plain NSView).
    @IBOutlet weak var moonPreviewView: NSView!
    
    // Pause/Resume toggle button outlet (to update its title)
    @IBOutlet weak var pauseToggleButton: NSButton!
    
    // Save & Close button (enable/disable based on validation)
    @IBOutlet weak var saveCloseButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    
    // Shared preview engine + timer
    private var previewEngine: StarryEngine?
    private var previewTimer: Timer?
    private var previewImageView: NSImageView?
    
    // Pause state tracking
    private var isManuallyPaused = false
    private var isAutoPaused = false   // set when window resigns key while not manually paused
    
    // Last-known values for change logging
    private var lastStarsPerUpdate: Int = 0
    private var lastBuildingHeight: Double = 0
    private var lastSecsBetweenClears: Double = 0
    private var lastMoonTraversalMinutes: Int = 0
    private var lastMinMoonRadius: Int = 0
    private var lastMaxMoonRadius: Int = 0
    private var lastBrightBrightness: Double = 0
    private var lastDarkBrightness: Double = 0
    private var lastMoonPhaseOverrideEnabled: Bool = false
    private var lastMoonPhaseOverrideValue: Double = 0.0
    private var lastShowLightAreaTextureFillMask: Bool = false
    
    // Shooting stars last-known
    private var lastShootingStarsEnabled: Bool = false
    private var lastShootingStarsAvgSeconds: Double = 0
    private var lastShootingStarsDirectionMode: Int = 0
    private var lastShootingStarsLength: Double = 0
    private var lastShootingStarsSpeed: Double = 0
    private var lastShootingStarsThickness: Double = 0
    private var lastShootingStarsBrightness: Double = 0
    private var lastShootingStarsTrailDecay: Double = 0
    private var lastShootingStarsDebugSpawnBounds: Bool = 0 != 0
    
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
    
    @IBAction func moonSliderChanged(_ sender: Any) {
        if minMoonRadiusSlider.integerValue != lastMinMoonRadius {
            logChange(changedKey: "moonMinRadius",
                      oldValue: "\(lastMinMoonRadius)",
                      newValue: "\(minMoonRadiusSlider.integerValue)")
            lastMinMoonRadius = minMoonRadiusSlider.integerValue
        }
        if maxMoonRadiusSlider.integerValue != lastMaxMoonRadius {
            logChange(changedKey: "moonMaxRadius",
                      oldValue: "\(lastMaxMoonRadius)",
                      newValue: "\(maxMoonRadiusSlider.integerValue)")
            lastMaxMoonRadius = maxMoonRadiusSlider.integerValue
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
        maybeClearAndRestartPreview(reason: "moonSliderChanged")
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
        
        minMoonRadiusSlider.integerValue = defaultsManager.moonMinRadius
        maxMoonRadiusSlider.integerValue = defaultsManager.moonMaxRadius
        brightBrightnessSlider.doubleValue = defaultsManager.moonBrightBrightness
        darkBrightnessSlider.doubleValue = defaultsManager.moonDarkBrightness
        
        moonPhaseOverrideCheckbox.state = defaultsManager.moonPhaseOverrideEnabled ? .on : .off
        moonPhaseSlider.doubleValue = defaultsManager.moonPhaseOverrideValue
        moonPhasePreview.stringValue = formatPhase(moonPhaseSlider.doubleValue)
        updatePhaseOverrideUIEnabled()
        
        showLightAreaTextureFillMaskCheckbox.state = defaultsManager.showLightAreaTextureFillMask ? .on : .off
        
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
        
        // Explicitly ensure key text fields are editable/selectable
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
        lastMinMoonRadius = minMoonRadiusSlider.integerValue
        lastMaxMoonRadius = maxMoonRadiusSlider.integerValue
        lastBrightBrightness = brightBrightnessSlider.doubleValue
        lastDarkBrightness = darkBrightnessSlider.doubleValue
        lastMoonPhaseOverrideEnabled = (moonPhaseOverrideCheckbox.state == .on)
        lastMoonPhaseOverrideValue = moonPhaseSlider.doubleValue
        lastShowLightAreaTextureFillMask = (showLightAreaTextureFillMaskCheckbox.state == .on)
        
        lastShootingStarsEnabled = (shootingStarsEnabledCheckbox.state == .on)
        lastShootingStarsAvgSeconds = shootingStarsAvgSecondsField.doubleValue
        lastShootingStarsDirectionMode = shootingStarsDirectionPopup.indexOfSelectedItem
        lastShootingStarsLength = shootingStarsLengthSlider.doubleValue
        lastShootingStarsSpeed = shootingStarsSpeedSlider.doubleValue
        lastShootingStarsThickness = shootingStarsThicknessSlider.doubleValue
        lastShootingStarsBrightness = shootingStarsBrightnessSlider.doubleValue
        lastShootingStarsTrailDecay = shootingStarsTrailDecaySlider.doubleValue
        lastShootingStarsDebugSpawnBounds = (shootingStarsDebugSpawnBoundsCheckbox.state == .on)
        
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
        saveCloseButton.keyEquivalent = "\r"     // Return to save
        cancelButton.keyEquivalent = "\u{1b}"    // Escape to cancel
    }
    
    private func applyAccessibility() {
        starsPerUpdate.setAccessibilityLabel("Stars per update")
        buildingHeightSlider.setAccessibilityLabel("Maximum building height")
        secsBetweenClears.setAccessibilityLabel("Seconds between clears")
        moonTraversalMinutes.setAccessibilityLabel("Moon traversal minutes")
        minMoonRadiusSlider.setAccessibilityLabel("Minimum moon radius")
        maxMoonRadiusSlider.setAccessibilityLabel("Maximum moon radius")
        brightBrightnessSlider.setAccessibilityLabel("Bright side brightness")
        darkBrightnessSlider.setAccessibilityLabel("Dark side brightness")
        moonPhaseOverrideCheckbox.setAccessibilityLabel("Lock moon phase")
        moonPhaseSlider.setAccessibilityLabel("Moon phase slider")
        showLightAreaTextureFillMaskCheckbox.setAccessibilityLabel("Show illuminated mask debug")
        shootingStarsEnabledCheckbox.setAccessibilityLabel("Enable shooting stars")
        shootingStarsAvgSecondsField.setAccessibilityLabel("Average seconds between shooting stars")
        shootingStarsDirectionPopup.setAccessibilityLabel("Shooting star direction mode")
        shootingStarsLengthSlider.setAccessibilityLabel("Shooting star length")
        shootingStarsSpeedSlider.setAccessibilityLabel("Shooting star speed")
        shootingStarsThicknessSlider.setAccessibilityLabel("Shooting star thickness")
        shootingStarsBrightnessSlider.setAccessibilityLabel("Shooting star brightness")
        shootingStarsTrailDecaySlider.setAccessibilityLabel("Shooting star trail decay")
        shootingStarsDebugSpawnBoundsCheckbox.setAccessibilityLabel("Debug: show spawn bounds")
        pauseToggleButton.setAccessibilityLabel("Pause or resume preview")
    }
    
    // MARK: - Validation
    
    private func inputsAreValid() -> Bool {
        return minMoonRadiusSlider.integerValue < maxMoonRadiusSlider.integerValue
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
        } else if field == shootingStarsAvgSecondsField {
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
    
    // MARK: - Preview Engine Management
    
    private func setupPreviewEngine() {
        guard let log = log else { return }
        guard moonPreviewView.bounds.width > 0, moonPreviewView.bounds.height > 0 else { return }
        
        if previewImageView == nil {
            let iv = NSImageView(frame: moonPreviewView.bounds)
            iv.autoresizingMask = [.width, .height]
            iv.imageScaling = .scaleProportionallyUpOrDown
            moonPreviewView.addSubview(iv)
            previewImageView = iv
        }
        
        previewEngine = StarryEngine(size: moonPreviewView.bounds.size,
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
        if let iv = previewImageView {
            iv.image = nil
            let size = moonPreviewView.bounds.size
            if size.width > 0 && size.height > 0 {
                let img = NSImage(size: size)
                img.lockFocus()
                NSColor.black.setFill()
                NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
                img.unlockFocus()
                iv.image = img
            }
        }
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
              let iv = previewImageView else { return }
        engine.resizeIfNeeded(newSize: moonPreviewView.bounds.size)
        if let cg = engine.advanceFrame() {
            iv.image = NSImage(cgImage: cg, size: moonPreviewView.bounds.size)
        }
    }
    
    private func currentPreviewRuntimeConfig() -> StarryRuntimeConfig {
        StarryRuntimeConfig(
            starsPerUpdate: starsPerUpdate.integerValue,
            buildingHeight: buildingHeightSlider.doubleValue,
            secsBetweenClears: secsBetweenClears.doubleValue,
            moonTraversalMinutes: moonTraversalMinutes.integerValue,
            moonMinRadius: minMoonRadiusSlider.integerValue,
            moonMaxRadius: maxMoonRadiusSlider.integerValue,
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
            shootingStarsDebugShowSpawnBounds: (shootingStarsDebugSpawnBoundsCheckbox.state == .on)
        )
    }
    
    private func updatePreviewConfig() {
        previewEngine?.updateConfig(currentPreviewRuntimeConfig())
    }
    
    private func updatePreviewLabels() {
        minMoonRadiusPreview.stringValue = "\(minMoonRadiusSlider.integerValue)"
        maxMoonRadiusPreview.stringValue = "\(maxMoonRadiusSlider.integerValue)"
        brightBrightnessPreview.stringValue = String(format: "%.2f", brightBrightnessSlider.doubleValue)
        darkBrightnessPreview.stringValue = String(format: "%.2f", darkBrightnessSlider.doubleValue)
        moonPhasePreview?.stringValue = formatPhase(moonPhaseSlider.doubleValue)
        
        shootingStarsLengthPreview?.stringValue = "\(Int(shootingStarsLengthSlider.doubleValue))"
        shootingStarsSpeedPreview?.stringValue = "\(Int(shootingStarsSpeedSlider.doubleValue))"
        shootingStarsThicknessPreview?.stringValue = String(format: "%.0f", shootingStarsThicknessSlider.doubleValue)
        shootingStarsBrightnessPreview?.stringValue = String(format: "%.2f", shootingStarsBrightnessSlider.doubleValue)
        shootingStarsTrailDecayPreview?.stringValue = String(format: "%.3f", shootingStarsTrailDecaySlider.doubleValue)
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
        defaultsManager.moonMinRadius = minMoonRadiusSlider.integerValue
        defaultsManager.moonMaxRadius = maxMoonRadiusSlider.integerValue
        defaultsManager.moonBrightBrightness = brightBrightnessSlider.doubleValue
        defaultsManager.moonDarkBrightness = darkBrightnessSlider.doubleValue
        defaultsManager.moonPhaseOverrideEnabled = (moonPhaseOverrideCheckbox.state == .on)
        defaultsManager.moonPhaseOverrideValue = moonPhaseSlider.doubleValue
        defaultsManager.showLightAreaTextureFillMask = (showLightAreaTextureFillMaskCheckbox.state == .on)
        
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
        return "starsPerUpdate=\(starsPerUpdate.integerValue)," +
               " buildingHeight=\(format(buildingHeightSlider.doubleValue))," +
               " secsBetweenClears=\(format(secsBetweenClears.doubleValue))," +
               " moonTraversalMinutes=\(moonTraversalMinutes.integerValue)," +
               " moonMinRadius=\(minMoonRadiusSlider.integerValue)," +
               " moonMaxRadius=\(maxMoonRadiusSlider.integerValue)," +
               " moonBrightBrightness=\(format(brightBrightnessSlider.doubleValue))," +
               " moonDarkBrightness=\(format(darkBrightnessSlider.doubleValue))," +
               " moonPhaseOverrideEnabled=\(moonPhaseOverrideCheckbox.state == .on)," +
               " moonPhaseOverrideValue=\(format(moonPhaseSlider.doubleValue))," +
               " showLightAreaTextureFillMask=\(showLightAreaTextureFillMaskCheckbox.state == .on)," +
               " shootingStarsEnabled=\(shootingStarsEnabledCheckbox.state == .on)," +
               " shootingStarsAvgSeconds=\(format(shootingStarsAvgSecondsField.doubleValue))," +
               " shootingStarsDirectionMode=\(shootingStarsDirectionPopup.indexOfSelectedItem)," +
               " shootingStarsLength=\(format(shootingStarsLengthSlider.doubleValue))," +
               " shootingStarsSpeed=\(format(shootingStarsSpeedSlider.doubleValue))," +
               " shootingStarsThickness=\(format(shootingStarsThicknessSlider.doubleValue))," +
               " shootingStarsBrightness=\(format(shootingStarsBrightnessSlider.doubleValue))," +
               " shootingStarsTrailDecay=\(format(shootingStarsTrailDecaySlider.doubleValue))," +
               " shootingStarsDebugSpawnBounds=\(shootingStarsDebugSpawnBoundsCheckbox.state == .on)"
    }
    
    private func format(_ d: Double) -> String {
        String(format: "%.3f", d)
    }
    
    private func formatPhase(_ d: Double) -> String {
        String(format: "%.3f", d)
    }
}
