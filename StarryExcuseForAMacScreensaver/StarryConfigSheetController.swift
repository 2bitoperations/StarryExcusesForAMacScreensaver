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
    
    // Shared preview engine + timer
    private var previewEngine: StarryEngine?
    private var previewTimer: Timer?
    private var previewImageView: NSImageView?
    
    // Pause state tracking
    private var isManuallyPaused = false
    private var isAutoPaused = false   // set when window resigns key while not manually paused
    
    // Minimum window content size (width x height) UPDATED to 640 x 480
    private let minContentSize = NSSize(width: 640, height: 480)
    
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
    
    @IBAction func previewPause(_ sender: Any) {
        isManuallyPaused = true
        pausePreview(auto: false)
    }
    
    @IBAction func previewResume(_ sender: Any) {
        isManuallyPaused = false
        if !isAutoPaused {
            resumePreview(auto: false)
        }
    }
    
    @IBAction func previewStep(_ sender: Any) {
        if previewTimer != nil { return }
        rebuildPreviewEngineIfNeeded()
        advancePreviewFrame()
    }
    
    // MARK: - Sheet lifecycle
    
    public func setView(view: StarryExcuseForAView) {
        self.view = view
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        window?.delegate = self
        
        // Ensure standard window chrome & resizable
        if let styleMask = window?.styleMask {
            window?.styleMask = styleMask
                .union(.titled)
                .union(.closable)
                .union(.resizable)
                .union(.miniaturizable)
        }
        window?.title = "Starry Excuses Configuration"
        window?.contentMinSize = minContentSize
        enforceMinimumSizeIfNeeded()
        
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
    }
    
    // Ensure window is at least min size on load
    private func enforceMinimumSizeIfNeeded() {
        guard let win = window else { return }
        var frame = win.frame
        var changed = false
        if frame.size.width < minContentSize.width {
            frame.size.width = minContentSize.width
            changed = true
        }
        if frame.size.height < minContentSize.height {
            let heightDelta = minContentSize.height - frame.size.height
            frame.origin.y -= heightDelta
            frame.size.height = minContentSize.height
            changed = true
        }
        if changed { win.setFrame(frame, display: true) }
    }
    
    // MARK: - Radius inequality enforcement (strict: min < max)
    private func enforceStrictRadiusInequality(changedControl: AnyObject?) {
        var minVal = minMoonRadiusSlider.integerValue
        var maxVal = maxMoonRadiusSlider.integerValue
        
        if minVal >= maxVal {
            if changedControl === minMoonRadiusSlider {
                // User moved min up to >= max; attempt to raise max first.
                if maxVal < Int(maxMoonRadiusSlider.maxValue) {
                    maxVal = min(minVal + 1, Int(maxMoonRadiusSlider.maxValue))
                } else {
                    // Can't raise max; pull min down.
                    minVal = max(maxVal - 1, Int(minMoonRadiusSlider.minValue))
                }
            } else if changedControl === maxMoonRadiusSlider {
                // User moved max down to <= min; attempt to lower min.
                if minVal > Int(minMoonRadiusSlider.minValue) {
                    minVal = max(minVal - 1, Int(minMoonRadiusSlider.minValue))
                } else {
                    // Can't lower min; push max up.
                    maxVal = min(minVal + 1, Int(maxMoonRadiusSlider.maxValue))
                }
            } else {
                // Initial load or unknown sender: prefer widening span by bumping max.
                if maxVal <= minVal && maxVal < Int(maxMoonRadiusSlider.maxValue) {
                    maxVal = minVal + 1
                } else {
                    minVal = maxVal - 1
                }
            }
        }
        
        // Apply updates
        minMoonRadiusSlider.integerValue = minVal
        maxMoonRadiusSlider.integerValue = maxVal
        
        // Dynamically adjust slider bounds to prevent equality on next drag:
        // min slider cannot reach current max; max slider cannot reach current min.
        minMoonRadiusSlider.maxValue = Double(maxVal - 1)
        maxMoonRadiusSlider.minValue = Double(minVal + 1)
    }
    
    // MARK: - Window Delegate (auto pause/resume & size enforcement)
    
    func windowDidResignKey(_ notification: Notification) {
        if !isManuallyPaused {
            pausePreview(auto: true)
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        if isAutoPaused && !isManuallyPaused {
            resumePreview(auto: true)
        }
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(minContentSize.width, frameSize.width),
               height: max(minContentSize.height, frameSize.height))
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
        // Leaving defaultsManager.normalizeMoonRadiusBounds() as-is (min <= max) since UI guarantees strict.
        
        view?.settingsChanged()
        
        window?.sheetParent?.endSheet(self.window!, returnCode: .OK)
        self.window?.close()
        
        os_log("exiting saveClose", log: self.log!, type: .info)
    }
    
    deinit { stopPreviewTimer() }
}
