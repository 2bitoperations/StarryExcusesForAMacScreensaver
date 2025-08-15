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
    
    // Phase override controls
    @IBOutlet weak var moonPhaseOverrideCheckbox: NSButton!
    @IBOutlet weak var moonPhaseSlider: NSSlider!
    @IBOutlet weak var moonPhasePreview: NSTextField!
    
    // Debug / troubleshooting: show illuminated texture fill mask
    @IBOutlet weak var showLightAreaTextureFillMaskCheckbox: NSButton!
    
    // Oversize override controls (deprecated, still shown)
    @IBOutlet weak var oversizeOverrideCheckbox: NSButton!
    @IBOutlet weak var oversizeOverrideSlider: NSSlider!
    @IBOutlet weak var oversizeOverridePreview: NSTextField!
    
    // Preview container (plain NSView).
    @IBOutlet weak var moonPreviewView: NSView!
    
    // Pause/Resume toggle button outlet (to update its title)
    @IBOutlet weak var pauseToggleButton: NSButton!
    
    // Save & Close button (enable/disable based on validation)
    @IBOutlet weak var saveCloseButton: NSButton!
    
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
    private var lastOversizeOverrideEnabled: Bool = false
    private var lastOversizeOverrideValue: Double = 1.25
    
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
    
    @IBAction func oversizeOverrideToggled(_ sender: Any) {
        let enabled = (oversizeOverrideCheckbox.state == .on)
        if enabled != lastOversizeOverrideEnabled {
            logChange(changedKey: "darkMinorityOversizeOverrideEnabled",
                      oldValue: lastOversizeOverrideEnabled ? "true" : "false",
                      newValue: enabled ? "true" : "false")
            lastOversizeOverrideEnabled = enabled
        }
        updateOversizeOverrideUIEnabled()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
        maybeClearAndRestartPreview(reason: "oversizeOverrideToggled")
    }
    
    @IBAction func oversizeOverrideSliderChanged(_ sender: Any) {
        let val = oversizeOverrideSlider.doubleValue
        oversizeOverridePreview.stringValue = String(format: "%.2f", val)
        if val != lastOversizeOverrideValue {
            logChange(changedKey: "darkMinorityOversizeOverrideValue",
                      oldValue: format(lastOversizeOverrideValue),
                      newValue: format(val))
            lastOversizeOverrideValue = val
        }
        if oversizeOverrideCheckbox.state == .on {
            rebuildPreviewEngineIfNeeded()
            updatePreviewConfig()
            maybeClearAndRestartPreview(reason: "oversizeOverrideSliderChanged")
        }
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
        
        if let win = window {
            win.styleMask = [.titled, .closable]
            win.title = "Starry Excuses Configuration"
            let desiredSize = NSSize(width: 800, height: 600)
            var frame = win.frame
            frame.origin.y -= (desiredSize.height - frame.size.height)
            frame.size = desiredSize
            win.setFrame(frame, display: true)
        }
        
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
        
        oversizeOverrideCheckbox.state = defaultsManager.darkMinorityOversizeOverrideEnabled ? .on : .off
        oversizeOverrideSlider.minValue = 0.5
        oversizeOverrideSlider.maxValue = 5.0
        oversizeOverrideSlider.doubleValue = defaultsManager.darkMinorityOversizeOverrideValue
        oversizeOverridePreview.stringValue = String(format: "%.2f", oversizeOverrideSlider.doubleValue)
        updateOversizeOverrideUIEnabled()
        
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
        lastOversizeOverrideEnabled = (oversizeOverrideCheckbox.state == .on)
        lastOversizeOverrideValue = oversizeOverrideSlider.doubleValue
        
        // Delegates
        starsPerUpdate.delegate = self
        secsBetweenClears.delegate = self
        moonTraversalMinutes.delegate = self
        
        updatePreviewLabels()
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        
        setupPreviewEngine()
        updatePauseToggleTitle()
        validateInputs()
        
        if let styleMaskRaw = window?.styleMask.rawValue {
            os_log("Config sheet loaded (styleMask raw=0x%{public}llx)", log: log!, type: .info, styleMaskRaw)
        } else {
            os_log("Config sheet loaded (no window style mask)", log: log!, type: .info)
        }
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
            darkMinorityOversizeOverrideEnabled: (oversizeOverrideCheckbox.state == .on),
            darkMinorityOversizeOverrideValue: oversizeOverrideSlider.doubleValue
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
        oversizeOverridePreview?.stringValue = String(format: "%.2f", oversizeOverrideSlider.doubleValue)
    }
    
    private func updateOversizeOverrideUIEnabled() {
        let enabled = oversizeOverrideCheckbox.state == .on
        oversizeOverrideSlider.isEnabled = enabled
        oversizeOverridePreview.isEnabled = enabled
        oversizeOverridePreview.alphaValue = enabled ? 1.0 : 0.5
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
        defaultsManager.darkMinorityOversizeOverrideEnabled = (oversizeOverrideCheckbox.state == .on)
        defaultsManager.darkMinorityOversizeOverrideValue = oversizeOverrideSlider.doubleValue
        
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
               " darkMinorityOversizeOverrideEnabled=\(oversizeOverrideCheckbox.state == .on)," +
               " darkMinorityOversizeOverrideValue=\(format(oversizeOverrideSlider.doubleValue))"
    }
    
    private func format(_ d: Double) -> String {
        String(format: "%.3f", d)
    }
    
    private func formatPhase(_ d: Double) -> String {
        String(format: "%.3f", d)
    }
}
