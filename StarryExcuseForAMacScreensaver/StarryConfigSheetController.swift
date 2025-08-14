//
//  ConfigurationSheetManager.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 5/2/19.
//

import Foundation
import Cocoa
import os

class StarryConfigSheetController : NSWindowController, NSWindowDelegate {
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
    
    // Preview container (plain NSView).
    @IBOutlet weak var moonPreviewView: NSView!
    
    // Pause/Resume toggle button outlet (to update its title)
    @IBOutlet weak var pauseToggleButton: NSButton!
    
    // Shared preview engine + timer
    private var previewEngine: StarryEngine?
    private var previewTimer: Timer?
    private var previewImageView: NSImageView?
    
    // Pause state tracking
    private var isManuallyPaused = false
    private var isAutoPaused = false   // set when window resigns key while not manually paused
    
    // MARK: - UI Actions (sliders)
    
    @IBAction func buildingHeightChanged(_ sender: Any) {
        buildingHeightPreview.stringValue = String(format: "%.3f", buildingHeightSlider.doubleValue)
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    @IBAction func moonSliderChanged(_ sender: Any) {
        // Enforce strict inequality: min < max
        enforceStrictRadiusInequality(changedControl: sender as AnyObject?)
        updatePreviewLabels()
        rebuildPreviewEngineIfNeeded()
        updatePreviewConfig()
    }
    
    // MARK: - Preview Control Buttons
    
    @IBAction func previewTogglePause(_ sender: Any) {
        if isManuallyPaused || effectivePaused() {
            // Resume
            isManuallyPaused = false
            if !isAutoPaused {
                resumePreview(auto: false)
            }
        } else {
            // Pause
            isManuallyPaused = true
            pausePreview(auto: false)
        }
        updatePauseToggleTitle()
    }
    
    @IBAction func previewStep(_ sender: Any) {
        // Single-step only when paused (manual or auto)
        if !effectivePaused() {
            // Force pause first
            isManuallyPaused = true
            pausePreview(auto: false)
        }
        rebuildPreviewEngineIfNeeded()
        advancePreviewFrame()
        updatePauseToggleTitle()
    }
    
    // MARK: - Sheet lifecycle
    
    public func setView(view: StarryExcuseForAView) {
        self.view = view
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        window?.delegate = self
        
        // Sheet style: titled & closable only (no resizing).
        if let win = window {
            win.styleMask = [.titled, .closable]
            win.title = "Starry Excuses Configuration"
            // Explicit fixed size 800x600 (matching XIB)
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
        
        // Enforce strict min < max at load (adjust if equal or inverted)
        enforceStrictRadiusInequality(changedControl: nil)
        
        updatePreviewLabels()
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        
        setupPreviewEngine()
        updatePauseToggleTitle()
        
        // Log raw style mask
        if let styleMaskRaw = window?.styleMask.rawValue {
            os_log("Config sheet loaded (styleMask raw=0x%{public}llx)", log: log!, type: .info, styleMaskRaw)
        } else {
            os_log("Config sheet loaded (no window style mask)", log: log!, type: .info)
        }
    }
    
    // MARK: - Radius inequality enforcement (strict: min < max)
    private func enforceStrictRadiusInequality(changedControl: AnyObject?) {
        var minVal = minMoonRadiusSlider.integerValue
        var maxVal = maxMoonRadiusSlider.integerValue
        
        if minVal >= maxVal {
            if changedControl === minMoonRadiusSlider {
                if maxVal < Int(maxMoonRadiusSlider.maxValue) {
                    maxVal = min(minVal + 1, Int(maxMoonRadiusSlider.maxValue))
                } else {
                    minVal = max(maxVal - 1, Int(minMoonRadiusSlider.minValue))
                }
            } else if changedControl === maxMoonRadiusSlider {
                if minVal > Int(minMoonRadiusSlider.minValue) {
                    minVal = max(minVal - 1, Int(minMoonRadiusSlider.minValue))
                } else {
                    maxVal = min(minVal + 1, Int(maxMoonRadiusSlider.maxValue))
                }
            } else {
                if maxVal <= minVal && maxVal < Int(maxMoonRadiusSlider.maxValue) {
                    maxVal = minVal + 1
                } else {
                    minVal = maxVal - 1
                }
            }
        }
        
        minMoonRadiusSlider.integerValue = minVal
        maxMoonRadiusSlider.integerValue = maxVal
        
        // Prevent equality on subsequent drags
        minMoonRadiusSlider.maxValue = Double(maxVal - 1)
        maxMoonRadiusSlider.minValue = Double(minVal + 1)
    }
    
    // MARK: - Window Delegate (auto pause/resume)
    
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
            traceEnabled: false
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
    }
    
    private func effectivePaused() -> Bool {
        return previewTimer == nil
    }
    
    private func updatePauseToggleTitle() {
        let title = effectivePaused() ? "Resume" : "Pause"
        pauseToggleButton?.title = title
    }
    
    // MARK: - Save / Close
    
    @IBAction func saveClose(_ sender: Any) {
        os_log("hit saveClose", log: self.log!, type: .info)
        
        // Final strict inequality enforcement before persisting.
        enforceStrictRadiusInequality(changedControl: nil)
        
        defaultsManager.starsPerUpdate = starsPerUpdate.integerValue
        defaultsManager.buildingHeight = buildingHeightSlider.doubleValue
        defaultsManager.secsBetweenClears = secsBetweenClears.doubleValue
        defaultsManager.moonTraversalMinutes = moonTraversalMinutes.integerValue
        defaultsManager.moonMinRadius = minMoonRadiusSlider.integerValue
        defaultsManager.moonMaxRadius = maxMoonRadiusSlider.integerValue
        defaultsManager.moonBrightBrightness = brightBrightnessSlider.doubleValue
        defaultsManager.moonDarkBrightness = darkBrightnessSlider.doubleValue
        
        view?.settingsChanged()
        
        window?.sheetParent?.endSheet(self.window!, returnCode: .OK)
        self.window?.close()
        
        os_log("exiting saveClose", log: self.log!, type: .info)
    }
    
    deinit { stopPreviewTimer() }
}
