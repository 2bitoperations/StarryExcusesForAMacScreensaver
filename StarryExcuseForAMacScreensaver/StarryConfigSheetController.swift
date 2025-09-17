import Foundation
import Cocoa
import os
import QuartzCore
import Metal

class StarryConfigSheetController : NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let defaultsManager = StarryDefaultsManager()
    weak var view: StarryExcuseForAView?
    private var log: OSLog?
    
    // MARK: - Former IBOutlets (now programmatically created)
    
    // General section (authoritative stars-per-second)
    var starsPerSecond: NSTextField!
    var buildingLightsPerSecond: NSTextField!
    var buildingHeightSlider: NSSlider?
    var buildingHeightPreview: NSTextField?
    var secsBetweenClears: NSTextField?          // now visible in UI
    var buildingFrequencySlider: NSSlider?
    var buildingFrequencyPreview: NSTextField?
    var debugOverlayEnabledCheckbox: NSSwitch?   // now visible in UI
    var shootingStarsDebugSpawnBoundsCheckbox: NSSwitch?   // moved to General section
    
    // Optional (not in simplified UI layout but retained for logic compatibility)
    var moonTraversalMinutes: NSTextField?
    
    // Moon sizing & brightness sliders
    var moonSizePercentSlider: NSSlider!          // present
    var brightBrightnessSlider: NSSlider?
    var darkBrightnessSlider: NSSlider?
    
    var moonSizePercentPreview: NSTextField!      // present
    var brightBrightnessPreview: NSTextField?
    var darkBrightnessPreview: NSTextField?
    
    // Phase override controls
    var moonPhaseOverrideCheckbox: NSSwitch?
    var moonPhaseSlider: NSSlider?
    var moonPhasePreview: NSTextField?
    
    // Debug toggle (moon mask)
    var showLightAreaTextureFillMaskCheckbox: NSSwitch?
    
    // Shooting Stars controls
    var shootingStarsEnabledCheckbox: NSSwitch!
    var shootingStarsAvgSecondsField: NSTextField!
    var shootingStarsDirectionPopup: NSPopUpButton?
    var shootingStarsLengthSlider: NSSlider?
    var shootingStarsSpeedSlider: NSSlider?
    var shootingStarsThicknessSlider: NSSlider?
    var shootingStarsBrightnessSlider: NSSlider?
    var shootingStarsTrailDecaySlider: NSSlider?
    var shootingStarsTrailHalfLifeSlider: NSSlider? { shootingStarsTrailDecaySlider }
    
    var shootingStarsLengthPreview: NSTextField?
    var shootingStarsSpeedPreview: NSTextField?
    var shootingStarsThicknessPreview: NSTextField?
    var shootingStarsBrightnessPreview: NSTextField?
    var shootingStarsTrailDecayPreview: NSTextField?
    var shootingStarsTrailHalfLifePreview: NSTextField? { shootingStarsTrailDecayPreview }
    
    // Satellites controls
    var satellitesEnabledCheckbox: NSSwitch?
    var satellitesAvgSecondsField: NSTextField?
    var satellitesPerMinuteSlider: NSSlider?
    var satellitesPerMinutePreview: NSTextField?
    var satellitesSpeedSlider: NSSlider?
    var satellitesSpeedPreview: NSTextField?
    var satellitesSizeSlider: NSSlider?
    var satellitesSizePreview: NSTextField?
    var satellitesBrightnessSlider: NSSlider?
    var satellitesBrightnessPreview: NSTextField?
    var satellitesTrailingCheckbox: NSSwitch?
    var satellitesTrailDecaySlider: NSSlider?
    var satellitesTrailDecayPreview: NSTextField?
    var satellitesTrailHalfLifeSlider: NSSlider? { satellitesTrailDecaySlider }
    var satellitesTrailHalfLifePreview: NSTextField? { satellitesTrailDecayPreview }
    
    // Preview container
    var moonPreviewView: NSView!
    
    // Buttons
    var pauseToggleButton: NSButton!
    var saveCloseButton: NSButton!
    var cancelButton: NSButton!
    
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
    
    // MARK: - One-time UI init flag
    private var uiInitialized = false
    
    // MARK: - Init
    
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1382, height: 1050),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Starry Excuses Settings"
        self.init(window: window)
    }
    
    override init(window: NSWindow?) {
        super.init(window: window)
        initializeProgrammaticUIIfNeeded()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported (XIB removed)")
    }
    
    public func setView(view: StarryExcuseForAView) {
        self.view = view
    }
    
    // Ensure UI is built (idempotent) before the sheet is displayed.
    private func initializeProgrammaticUIIfNeeded() {
        guard !uiInitialized, let _ = window else { return }
        uiInitialized = true
        
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        window?.delegate = self
        styleWindow()
        buildUI()
        populateDefaultsAndState()
        applyAccessibility()
        applyButtonKeyEquivalents()
        applySystemSymbolImages()
        if let renderer = previewRenderer {
            renderer.setDebugOverlayEnabled(lastDebugOverlayEnabled)
        }
        if let styleMaskRaw = window?.styleMask.rawValue, let log = log {
            os_log("Config sheet UI initialized early (styleMask raw=0x%{public}llx)", log: log, type: .info, styleMaskRaw)
        }
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        initializeProgrammaticUIIfNeeded()
    }
    
    // MARK: - Populate defaults
    
    private func populateDefaultsAndState() {
        guard starsPerSecond != nil else { return }
        
        starsPerSecond.integerValue = Int(round(defaultsManager.starsPerSecond))
        buildingLightsPerSecond.doubleValue = defaultsManager.buildingLightsPerSecond
        
        if let bhSlider = buildingHeightSlider {
            bhSlider.doubleValue = defaultsManager.buildingHeight
        }
        if let bhPrev = buildingHeightPreview, let bhSlider = buildingHeightSlider {
            bhPrev.stringValue = String(format: "%.2f%%", bhSlider.doubleValue * 100.0)
        }
        
        if let bfSlider = buildingFrequencySlider {
            bfSlider.doubleValue = defaultsManager.buildingFrequency
        }
        if let bfPrev = buildingFrequencyPreview, let bfSlider = buildingFrequencySlider {
            bfPrev.stringValue = String(format: "%.3f", bfSlider.doubleValue)
        }
        
        if let sbcField = secsBetweenClears {
            sbcField.doubleValue = defaultsManager.secsBetweenClears
        }
        
        debugOverlayEnabledCheckbox?.state = defaultsManager.debugOverlayEnabled ? .on : .off
        
        moonSizePercentSlider.doubleValue = defaultsManager.moonDiameterScreenWidthPercent
        
        // Moon brightness
        if let bright = brightBrightnessSlider {
            bright.doubleValue = defaultsManager.moonBrightBrightness
            brightBrightnessPreview?.stringValue = String(format: "%.3f", bright.doubleValue)
        }
        if let dark = darkBrightnessSlider {
            dark.doubleValue = defaultsManager.moonDarkBrightness
            darkBrightnessPreview?.stringValue = String(format: "%.3f", dark.doubleValue)
        }
        
        // Moon phase override
        if let phaseCB = moonPhaseOverrideCheckbox {
            phaseCB.state = defaultsManager.moonPhaseOverrideEnabled ? .on : .off
        }
        if let phaseSlider = moonPhaseSlider {
            phaseSlider.doubleValue = defaultsManager.moonPhaseOverrideValue
            moonPhasePreview?.stringValue = formatPhase(phaseSlider.doubleValue)
        }
        
        // Moon mask debug
        if let maskCB = showLightAreaTextureFillMaskCheckbox {
            maskCB.state = defaultsManager.showLightAreaTextureFillMask ? .on : .off
        }
        
        // Shooting stars
        shootingStarsEnabledCheckbox.state = defaultsManager.shootingStarsEnabled ? .on : .off
        shootingStarsAvgSecondsField.doubleValue = defaultsManager.shootingStarsAvgSeconds
        if let popup = shootingStarsDirectionPopup {
            popup.selectItem(at: defaultsManager.shootingStarsDirectionMode)
        }
        if let len = shootingStarsLengthSlider {
            len.doubleValue = defaultsManager.shootingStarsLength
            shootingStarsLengthPreview?.stringValue = String(format: "%.0f", len.doubleValue)
        }
        if let spd = shootingStarsSpeedSlider {
            spd.doubleValue = defaultsManager.shootingStarsSpeed
            shootingStarsSpeedPreview?.stringValue = String(format: "%.0f", spd.doubleValue)
        }
        if let thick = shootingStarsThicknessSlider {
            thick.doubleValue = defaultsManager.shootingStarsThickness
            shootingStarsThicknessPreview?.stringValue = String(format: "%.2f", thick.doubleValue)
        }
        if let bright = shootingStarsBrightnessSlider {
            bright.doubleValue = defaultsManager.shootingStarsBrightness
            shootingStarsBrightnessPreview?.stringValue = String(format: "%.3f", bright.doubleValue)
        }
        if let hl = shootingStarsTrailHalfLifeSlider {
            hl.doubleValue = defaultsManager.shootingStarsTrailHalfLifeSeconds
            shootingStarsTrailHalfLifePreview?.stringValue = String(format: "%.3f", hl.doubleValue)
        }
        
        // Spawn bounds (now general)
        shootingStarsDebugSpawnBoundsCheckbox?.state = defaultsManager.shootingStarsDebugShowSpawnBounds ? .on : .off
        
        // Satellites
        satellitesEnabledCheckbox?.state = defaultsManager.satellitesEnabled ? .on : .off
        satellitesAvgSecondsField?.doubleValue = defaultsManager.satellitesAvgSpawnSeconds
        
        if let speedSlider = satellitesSpeedSlider {
            speedSlider.doubleValue = defaultsManager.satellitesSpeed
            satellitesSpeedPreview?.stringValue = String(format: "%.1f", speedSlider.doubleValue)
        }
        if let sizeSlider = satellitesSizeSlider {
            sizeSlider.doubleValue = defaultsManager.satellitesSize
            satellitesSizePreview?.stringValue = String(format: "%.2f", sizeSlider.doubleValue)
        }
        if let brightnessSlider = satellitesBrightnessSlider {
            brightnessSlider.doubleValue = defaultsManager.satellitesBrightness
            satellitesBrightnessPreview?.stringValue = String(format: "%.3f", brightnessSlider.doubleValue)
        }
        if let trailingCB = satellitesTrailingCheckbox {
            trailingCB.state = defaultsManager.satellitesTrailing ? .on : .off
        }
        if let hlSlider = satellitesTrailHalfLifeSlider {
            hlSlider.doubleValue = defaultsManager.satellitesTrailHalfLifeSeconds
            satellitesTrailHalfLifePreview?.stringValue = String(format: "%.3f", hlSlider.doubleValue)
        }
        
        // Last-known capture
        lastStarsPerSecond = starsPerSecond.integerValue
        lastBuildingLightsPerSecond = buildingLightsPerSecond.doubleValue
        lastBuildingHeight = buildingHeightSlider?.doubleValue ?? defaultsManager.buildingHeight
        lastBuildingFrequency = buildingFrequencySlider?.doubleValue ?? defaultsManager.buildingFrequency
        lastSecsBetweenClears = secsBetweenClears?.doubleValue ?? defaultsManager.secsBetweenClears
        lastMoonSizePercent = moonSizePercentSlider.doubleValue
        lastBrightBrightness = brightBrightnessSlider?.doubleValue ?? defaultsManager.moonBrightBrightness
        lastDarkBrightness = darkBrightnessSlider?.doubleValue ?? defaultsManager.moonDarkBrightness
        lastMoonPhaseOverrideEnabled = moonPhaseOverrideCheckbox?.state == .on ? true : defaultsManager.moonPhaseOverrideEnabled
        lastMoonPhaseOverrideValue = moonPhaseSlider?.doubleValue ?? defaultsManager.moonPhaseOverrideValue
        lastShowLightAreaTextureFillMask = showLightAreaTextureFillMaskCheckbox?.state == .on ? true : defaultsManager.showLightAreaTextureFillMask
        lastShootingStarsEnabled = (shootingStarsEnabledCheckbox.state == .on)
        lastShootingStarsAvgSeconds = shootingStarsAvgSecondsField.doubleValue
        lastShootingStarsDirectionMode = shootingStarsDirectionPopup?.indexOfSelectedItem ?? defaultsManager.shootingStarsDirectionMode
        lastShootingStarsLength = shootingStarsLengthSlider?.doubleValue ?? defaultsManager.shootingStarsLength
        lastShootingStarsSpeed = shootingStarsSpeedSlider?.doubleValue ?? defaultsManager.shootingStarsSpeed
        lastShootingStarsThickness = shootingStarsThicknessSlider?.doubleValue ?? defaultsManager.shootingStarsThickness
        lastShootingStarsBrightness = shootingStarsBrightnessSlider?.doubleValue ?? defaultsManager.shootingStarsBrightness
        lastShootingStarsTrailHalfLifeSeconds = shootingStarsTrailHalfLifeSlider?.doubleValue ?? defaultsManager.shootingStarsTrailHalfLifeSeconds
        lastShootingStarsDebugSpawnBounds = shootingStarsDebugSpawnBoundsCheckbox?.state == .on ? true : defaultsManager.shootingStarsDebugShowSpawnBounds
        lastSatellitesEnabled = satellitesEnabledCheckbox?.state == .on
        lastSatellitesAvgSpawnSeconds = satellitesAvgSecondsField?.doubleValue ?? defaultsManager.satellitesAvgSpawnSeconds
        lastSatellitesSpeed = satellitesSpeedSlider?.doubleValue ?? defaultsManager.satellitesSpeed
        lastSatellitesSize = satellitesSizeSlider?.doubleValue ?? defaultsManager.satellitesSize
        lastSatellitesBrightness = satellitesBrightnessSlider?.doubleValue ?? defaultsManager.satellitesBrightness
        lastSatellitesTrailing = satellitesTrailingCheckbox?.state == .on
        lastSatellitesTrailHalfLifeSeconds = satellitesTrailHalfLifeSlider?.doubleValue ?? defaultsManager.satellitesTrailHalfLifeSeconds
        lastDebugOverlayEnabled = debugOverlayEnabledCheckbox?.state == .on
        
        updatePreviewLabels()
        updatePhaseOverrideUIEnabled()
        updateShootingStarsUIEnabled()
        updateSatellitesUIEnabled()
        
        setupPreviewEngine()
        updatePauseToggleTitle()
        validateInputs()
    }
    
    // MARK: - UI Construction
    
    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        
        let leftWidth: CGFloat = 320
        
        let leftContainer = NSView()
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        
        let docView = NSView()
        docView.frame = NSRect(x: 0, y: 0, width: leftWidth, height: 800)
        docView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = docView
        
        let sectionsStack = NSStackView()
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 16
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(sectionsStack)
        
        // GENERAL BOX
        let generalBox = makeBox(title: "General")
        let generalStack = makeVStack(spacing: 8)
        
        let starsRow = makeLabeledFieldRow(label: "Stars/second:",
                                           fieldWidth: 70,
                                           small: true) { tf in
            self.starsPerSecond = tf
        }
        let blRow = makeLabeledFieldRow(label: "Building lights/second:",
                                        fieldWidth: 70,
                                        small: true) { tf in
            self.buildingLightsPerSecond = tf
        }
        let sbcRow = makeLabeledFieldRow(label: "Seconds between clears:",
                                         fieldWidth: 70,
                                         small: true) { tf in
            self.secsBetweenClears = tf
        }
        
        // Building Height Slider (initial value sourced from defaults to avoid hard-coded duplicate)
        let bhLabelRow = NSStackView()
        bhLabelRow.orientation = .horizontal
        bhLabelRow.alignment = .firstBaseline
        bhLabelRow.spacing = 4
        bhLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let bhLabel = makeLabel("Building height (% of screen height)")
        let bhPreview = makeSmallLabel("0.00%")
        self.buildingHeightPreview = bhPreview
        bhLabelRow.addArrangedSubview(bhLabel)
        bhLabelRow.addArrangedSubview(bhPreview)
        let bhSlider = NSSlider(value: defaultsManager.buildingHeight,
                                minValue: 0.0,
                                maxValue: 1.0,
                                target: self,
                                action: #selector(buildingHeightChanged(_:)))
        bhSlider.translatesAutoresizingMaskIntoConstraints = false
        bhSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.buildingHeightSlider = bhSlider
        let bhSliderRow = NSStackView(views: [bhSlider])
        bhSliderRow.orientation = .horizontal
        bhSliderRow.alignment = .centerY
        bhSliderRow.spacing = 4
        bhSliderRow.translatesAutoresizingMaskIntoConstraints = false
        bhSlider.leadingAnchor.constraint(equalTo: bhSliderRow.leadingAnchor).isActive = true
        bhSlider.trailingAnchor.constraint(equalTo: bhSliderRow.trailingAnchor).isActive = true
        
        // Building Frequency Slider
        let bfLabelRow = NSStackView()
        bfLabelRow.orientation = .horizontal
        bfLabelRow.alignment = .firstBaseline
        bfLabelRow.spacing = 4
        bfLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let bfLabel = makeLabel("Building frequency")
        let bfPreview = makeSmallLabel("0.000")
        self.buildingFrequencyPreview = bfPreview
        bfLabelRow.addArrangedSubview(bfLabel)
        bfLabelRow.addArrangedSubview(bfPreview)
        let bfSlider = NSSlider(value: defaultsManager.buildingFrequency,
                                minValue: 0.001,
                                maxValue: 1.0,
                                target: self,
                                action: #selector(buildingFrequencyChanged(_:)))
        bfSlider.translatesAutoresizingMaskIntoConstraints = false
        bfSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.buildingFrequencySlider = bfSlider
        let bfSliderRow = NSStackView(views: [bfSlider])
        bfSliderRow.orientation = .horizontal
        bfSliderRow.alignment = .centerY
        bfSliderRow.spacing = 4
        bfSliderRow.translatesAutoresizingMaskIntoConstraints = false
        bfSlider.leadingAnchor.constraint(equalTo: bfSliderRow.leadingAnchor).isActive = true
        bfSlider.trailingAnchor.constraint(equalTo: bfSliderRow.trailingAnchor).isActive = true
        
        // Debug Overlay Toggle
        let debugOverlayRow = NSStackView()
        debugOverlayRow.orientation = .horizontal
        debugOverlayRow.alignment = .centerY
        debugOverlayRow.spacing = 6
        debugOverlayRow.translatesAutoresizingMaskIntoConstraints = false
        let debugSwitch = NSSwitch()
        debugSwitch.target = self
        debugSwitch.action = #selector(debugOverlayToggled(_:))
        self.debugOverlayEnabledCheckbox = debugSwitch
        let debugLabel = makeLabel("Show debug overlay")
        debugOverlayRow.addArrangedSubview(debugSwitch)
        debugOverlayRow.addArrangedSubview(debugLabel)
        
        // Spawn bounds (moved from Shooting Stars, renamed)
        let spawnBoundsRow = NSStackView()
        spawnBoundsRow.orientation = .horizontal
        spawnBoundsRow.alignment = .centerY
        spawnBoundsRow.spacing = 6
        spawnBoundsRow.translatesAutoresizingMaskIntoConstraints = false
        let spawnBoundsSwitch = NSSwitch()
        spawnBoundsSwitch.target = self
        spawnBoundsSwitch.action = #selector(shootingStarsDebugSpawnBoundsToggled(_:))
        self.shootingStarsDebugSpawnBoundsCheckbox = spawnBoundsSwitch
        let spawnBoundsLabel = makeLabel("Show satellite/shooting star spawn bounds")
        spawnBoundsRow.addArrangedSubview(spawnBoundsSwitch)
        spawnBoundsRow.addArrangedSubview(spawnBoundsLabel)
        
        generalStack.addArrangedSubview(starsRow)
        generalStack.addArrangedSubview(blRow)
        generalStack.addArrangedSubview(sbcRow)
        generalStack.addArrangedSubview(bhLabelRow)
        generalStack.addArrangedSubview(bhSliderRow)
        generalStack.addArrangedSubview(bfLabelRow)
        generalStack.addArrangedSubview(bfSliderRow)
        generalStack.addArrangedSubview(debugOverlayRow)
        generalStack.addArrangedSubview(spawnBoundsRow)
        generalBox.contentView?.addSubview(generalStack)
        if let generalContent = generalBox.contentView {
            pinToEdges(generalStack, in: generalContent, inset: 12)
        }
        
        // MOON BOX
        let moonBox = makeBox(title: "Moon")
        let moonStack = makeVStack(spacing: 8)
        
        // Size
        let moonLabelRow = NSStackView()
        moonLabelRow.orientation = .horizontal
        moonLabelRow.alignment = .firstBaseline
        moonLabelRow.spacing = 4
        moonLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let moonSizeLabel = makeLabel("Moon size (% of width)")
        let moonSizePreview = makeSmallLabel("0.00%")
        self.moonSizePercentPreview = moonSizePreview
        moonLabelRow.addArrangedSubview(moonSizeLabel)
        moonLabelRow.addArrangedSubview(moonSizePreview)
        let moonSlider = NSSlider(value: defaultsManager.moonDiameterScreenWidthPercent,
                                  minValue: 0.001,
                                  maxValue: 0.25,
                                  target: self,
                                  action: #selector(moonSliderChanged(_:)))
        moonSlider.translatesAutoresizingMaskIntoConstraints = false
        moonSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.moonSizePercentSlider = moonSlider
        let moonSliderRow = NSStackView(views: [moonSlider])
        moonSliderRow.orientation = .horizontal
        moonSliderRow.alignment = .centerY
        moonSliderRow.spacing = 4
        moonSliderRow.translatesAutoresizingMaskIntoConstraints = false
        moonSlider.leadingAnchor.constraint(equalTo: moonSliderRow.leadingAnchor).isActive = true
        moonSlider.trailingAnchor.constraint(equalTo: moonSliderRow.trailingAnchor).isActive = true
        
        // Bright-side brightness
        let brightRow = NSStackView()
        brightRow.orientation = .horizontal
        brightRow.alignment = .firstBaseline
        brightRow.spacing = 4
        brightRow.translatesAutoresizingMaskIntoConstraints = false
        let brightLabel = makeLabel("Bright-side brightness")
        let brightPreview = makeSmallLabel("1.000")
        self.brightBrightnessPreview = brightPreview
        brightRow.addArrangedSubview(brightLabel)
        brightRow.addArrangedSubview(brightPreview)
        let brightSlider = NSSlider(value: defaultsManager.moonBrightBrightness,
                                    minValue: 0.2,
                                    maxValue: 1.2,
                                    target: self,
                                    action: #selector(moonSliderChanged(_:)))
        brightSlider.translatesAutoresizingMaskIntoConstraints = false
        brightSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.brightBrightnessSlider = brightSlider
        let brightSliderRow = NSStackView(views: [brightSlider])
        brightSliderRow.orientation = .horizontal
        brightSliderRow.alignment = .centerY
        brightSliderRow.spacing = 4
        brightSliderRow.translatesAutoresizingMaskIntoConstraints = false
        brightSlider.leadingAnchor.constraint(equalTo: brightSliderRow.leadingAnchor).isActive = true
        brightSlider.trailingAnchor.constraint(equalTo: brightSliderRow.trailingAnchor).isActive = true
        
        // Dark-side brightness
        let darkRow = NSStackView()
        darkRow.orientation = .horizontal
        darkRow.alignment = .firstBaseline
        darkRow.spacing = 4
        darkRow.translatesAutoresizingMaskIntoConstraints = false
        let darkLabel = makeLabel("Dark-side brightness")
        let darkPreview = makeSmallLabel("0.150")
        self.darkBrightnessPreview = darkPreview
        darkRow.addArrangedSubview(darkLabel)
        darkRow.addArrangedSubview(darkPreview)
        let darkSlider = NSSlider(value: defaultsManager.moonDarkBrightness,
                                  minValue: 0.0,
                                  maxValue: 0.9,
                                  target: self,
                                  action: #selector(moonSliderChanged(_:)))
        darkSlider.translatesAutoresizingMaskIntoConstraints = false
        darkSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.darkBrightnessSlider = darkSlider
        let darkSliderRow = NSStackView(views: [darkSlider])
        darkSliderRow.orientation = .horizontal
        darkSliderRow.alignment = .centerY
        darkSliderRow.spacing = 4
        darkSliderRow.translatesAutoresizingMaskIntoConstraints = false
        darkSlider.leadingAnchor.constraint(equalTo: darkSliderRow.leadingAnchor).isActive = true
        darkSlider.trailingAnchor.constraint(equalTo: darkSliderRow.trailingAnchor).isActive = true
        
        // Phase override enable
        let phaseToggleRow = NSStackView()
        phaseToggleRow.orientation = .horizontal
        phaseToggleRow.alignment = .centerY
        phaseToggleRow.spacing = 6
        phaseToggleRow.translatesAutoresizingMaskIntoConstraints = false
        let phaseSwitch = NSSwitch()
        phaseSwitch.target = self
        phaseSwitch.action = #selector(moonPhaseOverrideToggled(_:))
        self.moonPhaseOverrideCheckbox = phaseSwitch
        let phaseToggleLabel = makeLabel("Enable phase override")
        phaseToggleRow.addArrangedSubview(phaseSwitch)
        phaseToggleRow.addArrangedSubview(phaseToggleLabel)
        
        // Phase slider
        let phaseRow = NSStackView()
        phaseRow.orientation = .horizontal
        phaseRow.alignment = .firstBaseline
        phaseRow.spacing = 4
        phaseRow.translatesAutoresizingMaskIntoConstraints = false
        let phaseLabel = makeLabel("Phase (0..1)")
        let phasePreview = makeSmallLabel("0.000")
        self.moonPhasePreview = phasePreview
        phaseRow.addArrangedSubview(phaseLabel)
        phaseRow.addArrangedSubview(phasePreview)
        let phaseSlider = NSSlider(value: defaultsManager.moonPhaseOverrideValue,
                                   minValue: 0.0,
                                   maxValue: 1.0,
                                   target: self,
                                   action: #selector(moonPhaseSliderChanged(_:)))
        phaseSlider.translatesAutoresizingMaskIntoConstraints = false
        phaseSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.moonPhaseSlider = phaseSlider
        let phaseSliderRow = NSStackView(views: [phaseSlider])
        phaseSliderRow.orientation = .horizontal
        phaseSliderRow.alignment = .centerY
        phaseSliderRow.spacing = 4
        phaseSliderRow.translatesAutoresizingMaskIntoConstraints = false
        phaseSlider.leadingAnchor.constraint(equalTo: phaseSliderRow.leadingAnchor).isActive = true
        phaseSlider.trailingAnchor.constraint(equalTo: phaseSliderRow.trailingAnchor).isActive = true
        
        // Show light-area texture fill mask (debug-ish)
        let maskRow = NSStackView()
        maskRow.orientation = .horizontal
        maskRow.alignment = .centerY
        maskRow.spacing = 6
        maskRow.translatesAutoresizingMaskIntoConstraints = false
        let maskSwitch = NSSwitch()
        maskSwitch.target = self
        maskSwitch.action = #selector(showLightAreaTextureFillMaskToggled(_:))
        self.showLightAreaTextureFillMaskCheckbox = maskSwitch
        let maskLabel = makeLabel("Show light-area fill mask")
        maskRow.addArrangedSubview(maskSwitch)
        maskRow.addArrangedSubview(maskLabel)
        
        // Add moon controls
        moonStack.addArrangedSubview(moonLabelRow)
        moonStack.addArrangedSubview(moonSliderRow)
        moonStack.addArrangedSubview(brightRow)
        moonStack.addArrangedSubview(brightSliderRow)
        moonStack.addArrangedSubview(darkRow)
        moonStack.addArrangedSubview(darkSliderRow)
        moonStack.addArrangedSubview(phaseToggleRow)
        moonStack.addArrangedSubview(phaseRow)
        moonStack.addArrangedSubview(phaseSliderRow)
        moonStack.addArrangedSubview(maskRow)
        
        moonBox.contentView?.addSubview(moonStack)
        if let moonContent = moonBox.contentView {
            pinToEdges(moonStack, in: moonContent, inset: 12)
        }
        
        // Enforce full-width for moon slider rows (excluding label-only rows if not desired)
        for row in [moonSliderRow, brightSliderRow, darkSliderRow, phaseSliderRow] {
            row.leadingAnchor.constraint(equalTo: moonStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: moonStack.trailingAnchor).isActive = true
        }
        
        // SHOOTING STARS
        let shootingBox = makeBox(title: "Shooting Stars")
        let shootingStack = makeVStack(spacing: 8)
        let shootingEnableRow = NSStackView()
        shootingEnableRow.orientation = .horizontal
        shootingEnableRow.alignment = .centerY
        shootingEnableRow.spacing = 6
        shootingEnableRow.translatesAutoresizingMaskIntoConstraints = false
        let shootingSwitch = NSSwitch()
        shootingSwitch.target = self
        shootingSwitch.action = #selector(shootingStarsToggled(_:))
        self.shootingStarsEnabledCheckbox = shootingSwitch
        let shootingLabel = makeLabel("Enable shooting stars")
        shootingEnableRow.addArrangedSubview(shootingSwitch)
        shootingEnableRow.addArrangedSubview(shootingLabel)
        let shootingAvgRow = makeLabeledFieldRow(label: "Seconds between stars:",
                                                 fieldWidth: 70,
                                                 small: true) { tf in
            self.shootingStarsAvgSecondsField = tf
            tf.target = self
            tf.action = #selector(shootingStarsAvgSecondsChanged(_:))
        }
        
        // Direction popup
        let dirRow = NSStackView()
        dirRow.orientation = .horizontal
        dirRow.alignment = .centerY
        dirRow.spacing = 4
        dirRow.translatesAutoresizingMaskIntoConstraints = false
        let dirLabel = makeLabel("Direction")
        let dirPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        dirPopup.translatesAutoresizingMaskIntoConstraints = false
        dirPopup.addItems(withTitles: [
            "Random",
            "Left → Right",
            "Right → Left",
            "TL → BR",
            "TR → BL"
        ])
        dirPopup.target = self
        dirPopup.action = #selector(shootingStarsDirectionChanged(_:))
        self.shootingStarsDirectionPopup = dirPopup
        dirRow.addArrangedSubview(dirLabel)
        dirRow.addArrangedSubview(dirPopup)
        dirPopup.widthAnchor.constraint(equalToConstant: 130).isActive = true
        
        // Length slider
        let lengthLabelRow = NSStackView()
        lengthLabelRow.orientation = .horizontal
        lengthLabelRow.alignment = .firstBaseline
        lengthLabelRow.spacing = 4
        lengthLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let lengthLabel = makeLabel("Length (px)")
        let lengthPreview = makeSmallLabel("160")
        self.shootingStarsLengthPreview = lengthPreview
        lengthLabelRow.addArrangedSubview(lengthLabel)
        lengthLabelRow.addArrangedSubview(lengthPreview)
        let lengthSlider = NSSlider(value: defaultsManager.shootingStarsLength,
                                    minValue: 40,
                                    maxValue: 300,
                                    target: self,
                                    action: #selector(shootingStarsSliderChanged(_:)))
        lengthSlider.translatesAutoresizingMaskIntoConstraints = false
        lengthSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.shootingStarsLengthSlider = lengthSlider
        let lengthSliderRow = NSStackView(views: [lengthSlider])
        lengthSliderRow.orientation = .horizontal
        lengthSliderRow.alignment = .centerY
        lengthSliderRow.spacing = 4
        lengthSliderRow.translatesAutoresizingMaskIntoConstraints = false
        lengthSlider.leadingAnchor.constraint(equalTo: lengthSliderRow.leadingAnchor).isActive = true
        lengthSlider.trailingAnchor.constraint(equalTo: lengthSliderRow.trailingAnchor).isActive = true
        
        // Speed slider
        let speedLabelRow = NSStackView()
        speedLabelRow.orientation = .horizontal
        speedLabelRow.alignment = .firstBaseline
        speedLabelRow.spacing = 4
        speedLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let speedLabel = makeLabel("Speed (px/s)")
        let speedPreview = makeSmallLabel("600")
        self.shootingStarsSpeedPreview = speedPreview
        speedLabelRow.addArrangedSubview(speedLabel)
        speedLabelRow.addArrangedSubview(speedPreview)
        let speedSlider = NSSlider(value: defaultsManager.shootingStarsSpeed,
                                   minValue: 200,
                                   maxValue: 1200,
                                   target: self,
                                   action: #selector(shootingStarsSliderChanged(_:)))
        speedSlider.translatesAutoresizingMaskIntoConstraints = false
        speedSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.shootingStarsSpeedSlider = speedSlider
        let speedSliderRow = NSStackView(views: [speedSlider])
        speedSliderRow.orientation = .horizontal
        speedSliderRow.alignment = .centerY
        speedSliderRow.spacing = 4
        speedSliderRow.translatesAutoresizingMaskIntoConstraints = false
        speedSlider.leadingAnchor.constraint(equalTo: speedSliderRow.leadingAnchor).isActive = true
        speedSlider.trailingAnchor.constraint(equalTo: speedSliderRow.trailingAnchor).isActive = true
        
        // Thickness slider
        let thickLabelRow = NSStackView()
        thickLabelRow.orientation = .horizontal
        thickLabelRow.alignment = .firstBaseline
        thickLabelRow.spacing = 4
        thickLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let thickLabel = makeLabel("Thickness (px)")
        let thickPreview = makeSmallLabel("2.00")
        self.shootingStarsThicknessPreview = thickPreview
        thickLabelRow.addArrangedSubview(thickLabel)
        thickLabelRow.addArrangedSubview(thickPreview)
        let thickSlider = NSSlider(value: defaultsManager.shootingStarsThickness,
                                   minValue: 1.0,
                                   maxValue: 4.0,
                                   target: self,
                                   action: #selector(shootingStarsSliderChanged(_:)))
        thickSlider.translatesAutoresizingMaskIntoConstraints = false
        thickSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.shootingStarsThicknessSlider = thickSlider
        let thickSliderRow = NSStackView(views: [thickSlider])
        thickSliderRow.orientation = .horizontal
        thickSliderRow.alignment = .centerY
        thickSliderRow.spacing = 4
        thickSliderRow.translatesAutoresizingMaskIntoConstraints = false
        thickSlider.leadingAnchor.constraint(equalTo: thickSliderRow.leadingAnchor).isActive = true
        thickSlider.trailingAnchor.constraint(equalTo: thickSliderRow.trailingAnchor).isActive = true
        
        // Brightness slider
        let brightSSLabelRow = NSStackView()
        brightSSLabelRow.orientation = .horizontal
        brightSSLabelRow.alignment = .firstBaseline
        brightSSLabelRow.spacing = 4
        brightSSLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let brightSSLabel = makeLabel("Brightness")
        let brightSSPreview = makeSmallLabel("0.200")
        self.shootingStarsBrightnessPreview = brightSSPreview
        brightSSLabelRow.addArrangedSubview(brightSSLabel)
        brightSSLabelRow.addArrangedSubview(brightSSPreview)
        let brightSSSlider = NSSlider(value: defaultsManager.shootingStarsBrightness,
                                      minValue: 0.0,
                                      maxValue: 1.0,
                                      target: self,
                                      action: #selector(shootingStarsSliderChanged(_:)))
        brightSSSlider.translatesAutoresizingMaskIntoConstraints = false
        brightSSSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.shootingStarsBrightnessSlider = brightSSSlider
        let brightSSSliderRow = NSStackView(views: [brightSSSlider])
        brightSSSliderRow.orientation = .horizontal
        brightSSSliderRow.alignment = .centerY
        brightSSSliderRow.spacing = 4
        brightSSSliderRow.translatesAutoresizingMaskIntoConstraints = false
        brightSSSlider.leadingAnchor.constraint(equalTo: brightSSSliderRow.leadingAnchor).isActive = true
        brightSSSlider.trailingAnchor.constraint(equalTo: brightSSSliderRow.trailingAnchor).isActive = true
        
        // Trail half-life
        let hlRow = NSStackView()
        hlRow.orientation = .horizontal
        hlRow.alignment = .firstBaseline
        hlRow.spacing = 4
        hlRow.translatesAutoresizingMaskIntoConstraints = false
        let hlLabel = makeLabel("Trail half-life (s)")
        let hlPreview = makeSmallLabel("0.180")
        self.shootingStarsTrailDecayPreview = hlPreview
        hlRow.addArrangedSubview(hlLabel)
        hlRow.addArrangedSubview(hlPreview)
        let hlSlider = NSSlider(value: defaultsManager.shootingStarsTrailHalfLifeSeconds,
                                minValue: 0.01,
                                maxValue: 2.0,
                                target: self,
                                action: #selector(shootingStarsSliderChanged(_:)))
        hlSlider.translatesAutoresizingMaskIntoConstraints = false
        hlSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.shootingStarsTrailDecaySlider = hlSlider
        let hlSliderRow = NSStackView(views: [hlSlider])
        hlSliderRow.orientation = .horizontal
        hlSliderRow.alignment = .centerY
        hlSliderRow.spacing = 4
        hlSliderRow.translatesAutoresizingMaskIntoConstraints = false
        hlSlider.leadingAnchor.constraint(equalTo: hlSliderRow.leadingAnchor).isActive = true
        hlSlider.trailingAnchor.constraint(equalTo: hlSliderRow.trailingAnchor).isActive = true
        
        shootingStack.addArrangedSubview(shootingEnableRow)
        shootingStack.addArrangedSubview(shootingAvgRow)
        shootingStack.addArrangedSubview(dirRow)
        shootingStack.addArrangedSubview(lengthLabelRow)
        shootingStack.addArrangedSubview(lengthSliderRow)
        shootingStack.addArrangedSubview(speedLabelRow)
        shootingStack.addArrangedSubview(speedSliderRow)
        shootingStack.addArrangedSubview(thickLabelRow)
        shootingStack.addArrangedSubview(thickSliderRow)
        shootingStack.addArrangedSubview(brightSSLabelRow)
        shootingStack.addArrangedSubview(brightSSSliderRow)
        shootingStack.addArrangedSubview(hlRow)
        shootingStack.addArrangedSubview(hlSliderRow)
        
        shootingBox.contentView?.addSubview(shootingStack)
        if let shootingContent = shootingBox.contentView {
            pinToEdges(shootingStack, in: shootingContent, inset: 12)
        }
        
        // Enforce full-width for shooting star slider rows
        for row in [lengthSliderRow, speedSliderRow, thickSliderRow, brightSSSliderRow, hlSliderRow] {
            row.leadingAnchor.constraint(equalTo: shootingStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: shootingStack.trailingAnchor).isActive = true
        }
        
        // SATELLITES
        let satellitesBox = makeBox(title: "Satellites")
        let satellitesStack = makeVStack(spacing: 8)
        
        // Enable row
        let satellitesEnableRow = NSStackView()
        satellitesEnableRow.orientation = .horizontal
        satellitesEnableRow.alignment = .centerY
        satellitesEnableRow.spacing = 6
        satellitesEnableRow.translatesAutoresizingMaskIntoConstraints = false
        let satellitesSwitch = NSSwitch()
        satellitesSwitch.target = self
        satellitesSwitch.action = #selector(satellitesToggled(_:))
        self.satellitesEnabledCheckbox = satellitesSwitch
        let satellitesLabel = makeLabel("Enable satellites")
        satellitesEnableRow.addArrangedSubview(satellitesSwitch)
        satellitesEnableRow.addArrangedSubview(satellitesLabel)
        
        // Avg seconds row
        let satellitesAvgRow = makeLabeledFieldRow(label: "Seconds between sats:",
                                                   fieldWidth: 70,
                                                   small: true) { tf in
            self.satellitesAvgSecondsField = tf
            tf.target = self
            tf.action = #selector(satellitesAvgSecondsChanged(_:))
        }
        
        // Speed slider
        let satSpeedLabelRow = NSStackView()
        satSpeedLabelRow.orientation = .horizontal
        satSpeedLabelRow.alignment = .firstBaseline
        satSpeedLabelRow.spacing = 4
        satSpeedLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let satSpeedLabel = makeLabel("Speed (px/sec)")
        let satSpeedPreview = makeSmallLabel("30.0")
        self.satellitesSpeedPreview = satSpeedPreview
        satSpeedLabelRow.addArrangedSubview(satSpeedLabel)
        satSpeedLabelRow.addArrangedSubview(satSpeedPreview)
        let satSpeedSlider = NSSlider(value: defaultsManager.satellitesSpeed,
                                      minValue: 1.0,
                                      maxValue: 100.0,
                                      target: self,
                                      action: #selector(satellitesSliderChanged(_:)))
        satSpeedSlider.translatesAutoresizingMaskIntoConstraints = false
        satSpeedSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.satellitesSpeedSlider = satSpeedSlider
        let satSpeedSliderRow = NSStackView(views: [satSpeedSlider])
        satSpeedSliderRow.orientation = .horizontal
        satSpeedSliderRow.alignment = .centerY
        satSpeedSliderRow.spacing = 4
        satSpeedSliderRow.translatesAutoresizingMaskIntoConstraints = false
        satSpeedSlider.leadingAnchor.constraint(equalTo: satSpeedSliderRow.leadingAnchor).isActive = true
        satSpeedSlider.trailingAnchor.constraint(equalTo: satSpeedSliderRow.trailingAnchor).isActive = true
        
        // Size slider
        let satSizeLabelRow = NSStackView()
        satSizeLabelRow.orientation = .horizontal
        satSizeLabelRow.alignment = .firstBaseline
        satSizeLabelRow.spacing = 4
        satSizeLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let satSizeLabel = makeLabel("Size (px)")
        let satSizePreview = makeSmallLabel("2.00")
        self.satellitesSizePreview = satSizePreview
        satSizeLabelRow.addArrangedSubview(satSizeLabel)
        satSizeLabelRow.addArrangedSubview(satSizePreview)
        let satSizeSlider = NSSlider(value: defaultsManager.satellitesSize,
                                     minValue: 1.0,
                                     maxValue: 6.0,
                                     target: self,
                                     action: #selector(satellitesSliderChanged(_:)))
        satSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        satSizeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.satellitesSizeSlider = satSizeSlider
        let satSizeSliderRow = NSStackView(views: [satSizeSlider])
        satSizeSliderRow.orientation = .horizontal
        satSizeSliderRow.alignment = .centerY
        satSizeSliderRow.spacing = 4
        satSizeSliderRow.translatesAutoresizingMaskIntoConstraints = false
        satSizeSlider.leadingAnchor.constraint(equalTo: satSizeSliderRow.leadingAnchor).isActive = true
        satSizeSlider.trailingAnchor.constraint(equalTo: satSizeSliderRow.trailingAnchor).isActive = true
        
        // Brightness slider
        let satBrightnessLabelRow = NSStackView()
        satBrightnessLabelRow.orientation = .horizontal
        satBrightnessLabelRow.alignment = .firstBaseline
        satBrightnessLabelRow.spacing = 4
        satBrightnessLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let satBrightnessLabel = makeLabel("Brightness")
        let satBrightnessPreview = makeSmallLabel("0.500")
        self.satellitesBrightnessPreview = satBrightnessPreview
        satBrightnessLabelRow.addArrangedSubview(satBrightnessLabel)
        satBrightnessLabelRow.addArrangedSubview(satBrightnessPreview)
        let satBrightnessSlider = NSSlider(value: defaultsManager.satellitesBrightness,
                                           minValue: 0.2,
                                           maxValue: 1.2,
                                           target: self,
                                           action: #selector(satellitesSliderChanged(_:)))
        satBrightnessSlider.translatesAutoresizingMaskIntoConstraints = false
        satBrightnessSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.satellitesBrightnessSlider = satBrightnessSlider
        let satBrightnessSliderRow = NSStackView(views: [satBrightnessSlider])
        satBrightnessSliderRow.orientation = .horizontal
        satBrightnessSliderRow.alignment = .centerY
        satBrightnessSliderRow.spacing = 4
        satBrightnessSliderRow.translatesAutoresizingMaskIntoConstraints = false
        satBrightnessSlider.leadingAnchor.constraint(equalTo: satBrightnessSliderRow.leadingAnchor).isActive = true
        satBrightnessSlider.trailingAnchor.constraint(equalTo: satBrightnessSliderRow.trailingAnchor).isActive = true
        
        // Trailing toggle
        let satTrailingRow = NSStackView()
        satTrailingRow.orientation = .horizontal
        satTrailingRow.alignment = .centerY
        satTrailingRow.spacing = 6
        satTrailingRow.translatesAutoresizingMaskIntoConstraints = false
        let satTrailingSwitch = NSSwitch()
        satTrailingSwitch.target = self
        satTrailingSwitch.action = #selector(satellitesTrailingToggled(_:))
        self.satellitesTrailingCheckbox = satTrailingSwitch
        let satTrailingLabel = makeLabel("Enable trailing")
        satTrailingRow.addArrangedSubview(satTrailingSwitch)
        satTrailingRow.addArrangedSubview(satTrailingLabel)
        
        // Trail half-life slider
        let satHLLabelRow = NSStackView()
        satHLLabelRow.orientation = .horizontal
        satHLLabelRow.alignment = .firstBaseline
        satHLLabelRow.spacing = 4
        satHLLabelRow.translatesAutoresizingMaskIntoConstraints = false
        let satHLLabel = makeLabel("Trail half-life (s)")
        let satHLPreview = makeSmallLabel("0.100")
        self.satellitesTrailDecayPreview = satHLPreview
        satHLLabelRow.addArrangedSubview(satHLLabel)
        satHLLabelRow.addArrangedSubview(satHLPreview)
        let satHLSlider = NSSlider(value: defaultsManager.satellitesTrailHalfLifeSeconds,
                                   minValue: 0.0,
                                   maxValue: 0.5,
                                   target: self,
                                   action: #selector(satellitesSliderChanged(_:)))
        satHLSlider.translatesAutoresizingMaskIntoConstraints = false
        satHLSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.satellitesTrailDecaySlider = satHLSlider
        let satHLSliderRow = NSStackView(views: [satHLSlider])
        satHLSliderRow.orientation = .horizontal
        satHLSliderRow.alignment = .centerY
        satHLSliderRow.spacing = 4
        satHLSliderRow.translatesAutoresizingMaskIntoConstraints = false
        satHLSlider.leadingAnchor.constraint(equalTo: satHLSliderRow.leadingAnchor).isActive = true
        satHLSlider.trailingAnchor.constraint(equalTo: satHLSliderRow.trailingAnchor).isActive = true
        
        // Assemble satellites stack
        satellitesStack.addArrangedSubview(satellitesEnableRow)
        satellitesStack.addArrangedSubview(satellitesAvgRow)
        satellitesStack.addArrangedSubview(satSpeedLabelRow)
        satellitesStack.addArrangedSubview(satSpeedSliderRow)
        satellitesStack.addArrangedSubview(satSizeLabelRow)
        satellitesStack.addArrangedSubview(satSizeSliderRow)
        satellitesStack.addArrangedSubview(satBrightnessLabelRow)
        satellitesStack.addArrangedSubview(satBrightnessSliderRow)
        satellitesStack.addArrangedSubview(satTrailingRow)
        satellitesStack.addArrangedSubview(satHLLabelRow)
        satellitesStack.addArrangedSubview(satHLSliderRow)
        
        satellitesBox.contentView?.addSubview(satellitesStack)
        if let satContent = satellitesBox.contentView {
            pinToEdges(satellitesStack, in: satContent, inset: 12)
        }
        
        // Enforce full-width for satellite slider rows
        for row in [satSpeedSliderRow, satSizeSliderRow, satBrightnessSliderRow, satHLSliderRow] {
            row.leadingAnchor.constraint(equalTo: satellitesStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: satellitesStack.trailingAnchor).isActive = true
        }
        
        // Add sections
        sectionsStack.addArrangedSubview(generalBox)
        sectionsStack.addArrangedSubview(moonBox)
        sectionsStack.addArrangedSubview(shootingBox)
        sectionsStack.addArrangedSubview(satellitesBox)
        
        // Force full-width for non-General sections so their right edges align with scrollable area.
        // (General already appears visually correct; leave it as-is.)
        let boxesToExpand: [NSBox] = [moonBox, shootingBox, satellitesBox]
        for box in boxesToExpand {
            box.setContentHuggingPriority(.defaultLow, for: .horizontal)
            box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            box.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
        }
        
        NSLayoutConstraint.activate([
            sectionsStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 12),
            sectionsStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 12),
            sectionsStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -12),
            sectionsStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -12),
            docView.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
        
        leftContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor)
        ])
        
        let buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 12
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false
        
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveClose(_:)))
        saveBtn.setButtonType(.momentaryPushIn)
        saveBtn.bezelStyle = .rounded
        self.saveCloseButton = saveBtn
        
        let pauseBtn = NSButton(title: "Pause", target: self, action: #selector(previewTogglePause(_:)))
        pauseBtn.setButtonType(.momentaryPushIn)
        pauseBtn.bezelStyle = .rounded
        self.pauseToggleButton = pauseBtn
        
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClose(_:)))
        cancelBtn.setButtonType(.momentaryPushIn)
        cancelBtn.bezelStyle = .rounded
        self.cancelButton = cancelBtn
        
        buttonsRow.addArrangedSubview(saveBtn)
        buttonsRow.addArrangedSubview(pauseBtn)
        buttonsRow.addArrangedSubview(cancelBtn)
        
        leftContainer.addSubview(buttonsRow)
        NSLayoutConstraint.activate([
            buttonsRow.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 12),
            buttonsRow.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: buttonsRow.topAnchor, constant: -8)
        ])
        
        let preview = NSView()
        preview.wantsLayer = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        self.moonPreviewView = preview
        
        contentView.addSubview(leftContainer)
        contentView.addSubview(preview)
        
        NSLayoutConstraint.activate([
            leftContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leftContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            leftContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            leftContainer.widthAnchor.constraint(equalToConstant: leftWidth),
            
            preview.leadingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            preview.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            preview.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
        
        starsPerSecond.delegate = self
        buildingLightsPerSecond.delegate = self
        secsBetweenClears?.delegate = self
        shootingStarsAvgSecondsField.delegate = self
        satellitesAvgSecondsField?.delegate = self
        
        // Align text fields' right edges with scroll area's right edge by constraining rows.
        for row in [starsRow, blRow, sbcRow] {
            row.trailingAnchor.constraint(equalTo: generalStack.trailingAnchor).isActive = true
        }
        if let shootingAvgRow = shootingStarsAvgSecondsField?.superview as? NSStackView,
           let shootingParent = shootingAvgRow.superview {
            shootingAvgRow.trailingAnchor.constraint(equalTo: shootingParent.trailingAnchor).isActive = true
        }
        if let satsAvgRow = satellitesAvgSecondsField?.superview as? NSStackView,
           let satsParent = satsAvgRow.superview {
            satsAvgRow.trailingAnchor.constraint(equalTo: satsParent.trailingAnchor).isActive = true
        }
        
        contentView.layoutSubtreeIfNeeded()
        
        if let log = log {
            os_log("buildUI completed (sections=%{public}d)", log: log, type: .info, sectionsStack.arrangedSubviews.count)
        }
    }
    
    // MARK: - View Builders
    
    private func makeBox(title: String) -> NSBox {
        let box = NSBox()
        box.boxType = .primary
        box.title = title
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentViewMargins = NSSize(width: 0, height: 0)
        return box
    }
    
    private func makeVStack(spacing: CGFloat) -> NSStackView {
        let stk = NSStackView()
        stk.orientation = .vertical
        stk.alignment = .leading
        stk.spacing = spacing
        stk.translatesAutoresizingMaskIntoConstraints = false
        return stk
    }
    
    private func makeLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
    }
    
    private func makeSmallLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
    }
    
    private func makeLabeledFieldRow(label: String,
                                     fieldWidth: CGFloat,
                                     small: Bool,
                                     bindField: (NSTextField) -> Void) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        
        let lbl = makeLabel(label)
        if small {
            lbl.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }
        
        // Flexible spacer to push the fixed-width text field to the right edge.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        let tf = NSTextField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.alignment = .left
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBordered = true
        tf.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.controlSize = .small
        tf.cell?.usesSingleLineMode = true
        tf.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(tf)
        
        tf.setContentHuggingPriority(.required, for: .horizontal)
        tf.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        bindField(tf)
        return row
    }
    
    private func pinToEdges(_ view: NSView, in superview: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: superview.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: superview.trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(lessThanOrEqualTo: superview.bottomAnchor, constant: -inset)
        ])
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
        secsBetweenClears?.setAccessibilityLabel("Seconds between clears")
        buildingHeightSlider?.setAccessibilityLabel("Building height fraction of screen")
        buildingFrequencySlider?.setAccessibilityLabel("Building frequency")
        debugOverlayEnabledCheckbox?.setAccessibilityLabel("Show debug overlay")
        shootingStarsDebugSpawnBoundsCheckbox?.setAccessibilityLabel("Show satellite and shooting star spawn bounds")
        moonSizePercentSlider.setAccessibilityLabel("Moon size as percent of screen width")
        brightBrightnessSlider?.setAccessibilityLabel("Moon bright side brightness")
        darkBrightnessSlider?.setAccessibilityLabel("Moon dark side brightness")
        moonPhaseOverrideCheckbox?.setAccessibilityLabel("Enable moon phase override")
        moonPhaseSlider?.setAccessibilityLabel("Moon phase override value")
        showLightAreaTextureFillMaskCheckbox?.setAccessibilityLabel("Show moon light-area texture fill mask")
        shootingStarsEnabledCheckbox.setAccessibilityLabel("Enable shooting stars")
        shootingStarsAvgSecondsField.setAccessibilityLabel("Average seconds between shooting stars")
        shootingStarsDirectionPopup?.setAccessibilityLabel("Shooting stars direction mode")
        shootingStarsLengthSlider?.setAccessibilityLabel("Shooting stars length in pixels")
        shootingStarsSpeedSlider?.setAccessibilityLabel("Shooting stars speed in pixels per second")
        shootingStarsThicknessSlider?.setAccessibilityLabel("Shooting stars thickness in pixels")
        shootingStarsBrightnessSlider?.setAccessibilityLabel("Shooting stars brightness")
        shootingStarsTrailHalfLifeSlider?.setAccessibilityLabel("Shooting stars trail half-life seconds")
        satellitesEnabledCheckbox?.setAccessibilityLabel("Enable satellites layer")
        satellitesAvgSecondsField?.setAccessibilityLabel("Average seconds between satellites")
        satellitesSpeedSlider?.setAccessibilityLabel("Satellites speed pixels per second")
        satellitesSizeSlider?.setAccessibilityLabel("Satellites size in pixels")
        satellitesBrightnessSlider?.setAccessibilityLabel("Satellites brightness")
        satellitesTrailingCheckbox?.setAccessibilityLabel("Enable satellites trailing")
        satellitesTrailHalfLifeSlider?.setAccessibilityLabel("Satellites trail half-life seconds")
        pauseToggleButton.setAccessibilityLabel("Pause or resume preview")
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
            var newVal = field.doubleValue
            if newVal < 1.0 { newVal = 1.0; field.doubleValue = newVal }
            if newVal != lastSecsBetweenClears {
                logChange(changedKey: "secsBetweenClears",
                          oldValue: format(lastSecsBetweenClears),
                          newValue: format(newVal))
                lastSecsBetweenClears = newVal
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
    
    // MARK: - Actions
    
    @IBAction func buildingHeightChanged(_ sender: Any) {
        guard let slider = buildingHeightSlider else { return }
        let oldVal = lastBuildingHeight
        let newVal = slider.doubleValue
        buildingHeightPreview?.stringValue = String(format: "%.2f%%", newVal * 100.0)
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
        buildingFrequencyPreview?.stringValue = String(format: "%.3f", newVal)
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
            shootingStarsDebugShowSpawnBounds: shootingStarsDebugSpawnBoundsCheckbox?.state == .on,
            satellitesEnabled: satellitesEnabledCheckbox?.state == .on,
            satellitesAvgSpawnSeconds: satellitesAvg,
            satellitesSpeed: satellitesSpeedSlider?.doubleValue ?? lastSatellitesSpeed,
            satellitesSize: satellitesSizeSlider?.doubleValue ?? lastSatellitesSize,
            satellitesBrightness: satellitesBrightnessSlider?.doubleValue ?? lastSatellitesBrightness,
            satellitesTrailing: satellitesTrailingCheckbox?.state == .on,
            debugOverlayEnabled: debugOverlayEnabledCheckbox?.state == .on,
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
        let percent = moonSizePercentSlider.doubleValue * 100.0
        moonSizePercentPreview.stringValue = String(format: "%.2f%%", percent)
        if let bhSlider = buildingHeightSlider, let bhPrev = buildingHeightPreview {
            bhPrev.stringValue = String(format: "%.2f%%", bhSlider.doubleValue * 100.0)
        }
        if let bfSlider = buildingFrequencySlider, let bfPrev = buildingFrequencyPreview {
            bfPrev.stringValue = String(format: "%.3f", bfSlider.doubleValue)
        }
        if let bright = brightBrightnessSlider, let brightPrev = brightBrightnessPreview {
            brightPrev.stringValue = String(format: "%.3f", bright.doubleValue)
        }
        if let dark = darkBrightnessSlider, let darkPrev = darkBrightnessPreview {
            darkPrev.stringValue = String(format: "%.3f", dark.doubleValue)
        }
        if let phaseSlider = moonPhaseSlider, let phasePrev = moonPhasePreview {
            phasePrev.stringValue = formatPhase(phaseSlider.doubleValue)
        }
        // Shooting stars previews
        if let len = shootingStarsLengthSlider, let lbl = shootingStarsLengthPreview {
            lbl.stringValue = String(format: "%.0f", len.doubleValue)
        }
        if let spd = shootingStarsSpeedSlider, let lbl = shootingStarsSpeedPreview {
            lbl.stringValue = String(format: "%.0f", spd.doubleValue)
        }
        if let thk = shootingStarsThicknessSlider, let lbl = shootingStarsThicknessPreview {
            lbl.stringValue = String(format: "%.2f", thk.doubleValue)
        }
        if let br = shootingStarsBrightnessSlider, let lbl = shootingStarsBrightnessPreview {
            lbl.stringValue = String(format: "%.3f", br.doubleValue)
        }
        if let hl = shootingStarsTrailHalfLifeSlider, let lbl = shootingStarsTrailHalfLifePreview {
            lbl.stringValue = String(format: "%.3f", hl.doubleValue)
        }
        if let satSpeed = satellitesSpeedSlider, let lbl = satellitesSpeedPreview {
            lbl.stringValue = String(format: "%.1f", satSpeed.doubleValue)
        }
        if let satSize = satellitesSizeSlider, let lbl = satellitesSizePreview {
            lbl.stringValue = String(format: "%.2f", satSize.doubleValue)
        }
        if let satBright = satellitesBrightnessSlider, let lbl = satellitesBrightnessPreview {
            lbl.stringValue = String(format: "%.3f", satBright.doubleValue)
        }
        if let hl = satellitesTrailHalfLifeSlider, let lbl = satellitesTrailHalfLifePreview {
            lbl.stringValue = String(format: "%.3f", hl.doubleValue)
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
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        let controls: [NSControl?] = [
            shootingStarsAvgSecondsField,
            shootingStarsDirectionPopup,
            shootingStarsLengthSlider,
            shootingStarsSpeedSlider,
            shootingStarsThicknessSlider,
            shootingStarsBrightnessSlider,
            shootingStarsTrailHalfLifeSlider
            // (spawn bounds checkbox now in General section; always enabled)
        ]
        for c in controls {
            c?.isEnabled = enabled
            c?.alphaValue = alpha
        }
        shootingStarsLengthPreview?.alphaValue = alpha
        shootingStarsSpeedPreview?.alphaValue = alpha
        shootingStarsThicknessPreview?.alphaValue = alpha
        shootingStarsBrightnessPreview?.alphaValue = alpha
        shootingStarsTrailHalfLifePreview?.alphaValue = alpha
    }
    
    private func updateSatellitesUIEnabled() {
        guard let enabledCheckbox = satellitesEnabledCheckbox else { return }
        let enabled = enabledCheckbox.state == .on
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        let controls: [NSControl?] = [
            satellitesAvgSecondsField,
            satellitesSpeedSlider,
            satellitesSizeSlider,
            satellitesBrightnessSlider,
            satellitesTrailingCheckbox,
            satellitesTrailHalfLifeSlider
        ]
        for c in controls {
            c?.isEnabled = enabled
            c?.alphaValue = alpha
        }
        // Preview labels
        satellitesSpeedPreview?.alphaValue = alpha
        satellitesSizePreview?.alphaValue = alpha
        satellitesBrightnessPreview?.alphaValue = alpha
        satellitesTrailHalfLifePreview?.alphaValue = alpha
    }
    
    // MARK: - Save / Close / Cancel
    
    @IBAction func saveClose(_ sender: Any) {
        guard inputsAreValid() else {
            NSSound.beep()
            return
        }
        
        os_log("hit saveClose", log: self.log ?? OSLog.default, type: .info)
        
        defaultsManager.starsPerSecond = Double(starsPerSecond.integerValue)
        defaultsManager.buildingLightsPerSecond = buildingLightsPerSecond.doubleValue
        defaultsManager.moonDiameterScreenWidthPercent = moonSizePercentSlider.doubleValue
        if let bh = buildingHeightSlider {
            defaultsManager.buildingHeight = bh.doubleValue
        }
        if let bf = buildingFrequencySlider {
            defaultsManager.buildingFrequency = bf.doubleValue
        }
        if let sbcField = secsBetweenClears {
            defaultsManager.secsBetweenClears = sbcField.doubleValue
        }
        if let debugSwitch = debugOverlayEnabledCheckbox {
            defaultsManager.debugOverlayEnabled = (debugSwitch.state == .on)
        }
        
        // Moon extras
        if let bright = brightBrightnessSlider {
            defaultsManager.moonBrightBrightness = bright.doubleValue
        }
        if let dark = darkBrightnessSlider {
            defaultsManager.moonDarkBrightness = dark.doubleValue
        }
        if let phaseCB = moonPhaseOverrideCheckbox {
            defaultsManager.moonPhaseOverrideEnabled = (phaseCB.state == .on)
        }
        if let phaseSlider = moonPhaseSlider {
            defaultsManager.moonPhaseOverrideValue = phaseSlider.doubleValue
        }
        if let maskCB = showLightAreaTextureFillMaskCheckbox {
            defaultsManager.showLightAreaTextureFillMask = (maskCB.state == .on)
        }
        
        // Shooting stars
        defaultsManager.shootingStarsEnabled = (shootingStarsEnabledCheckbox.state == .on)
        defaultsManager.shootingStarsAvgSeconds = shootingStarsAvgSecondsField.doubleValue
        if let popup = shootingStarsDirectionPopup {
            defaultsManager.shootingStarsDirectionMode = popup.indexOfSelectedItem
        }
        if let len = shootingStarsLengthSlider {
            defaultsManager.shootingStarsLength = len.doubleValue
        }
        if let spd = shootingStarsSpeedSlider {
            defaultsManager.shootingStarsSpeed = spd.doubleValue
        }
        if let thk = shootingStarsThicknessSlider {
            defaultsManager.shootingStarsThickness = thk.doubleValue
        }
        if let br = shootingStarsBrightnessSlider {
            defaultsManager.shootingStarsBrightness = br.doubleValue
        }
        if let hl = shootingStarsTrailHalfLifeSlider {
            defaultsManager.shootingStarsTrailHalfLifeSeconds = hl.doubleValue
        }
        if let dbg = shootingStarsDebugSpawnBoundsCheckbox {
            defaultsManager.shootingStarsDebugShowSpawnBounds = (dbg.state == .on)
        }
        
        // Satellites
        if let cb = satellitesEnabledCheckbox {
            defaultsManager.satellitesEnabled = (cb.state == .on)
        }
        if let secsField = satellitesAvgSecondsField {
            defaultsManager.satellitesAvgSpawnSeconds = secsField.doubleValue
        }
        if let speed = satellitesSpeedSlider {
            defaultsManager.satellitesSpeed = speed.doubleValue
        }
        if let size = satellitesSizeSlider {
            defaultsManager.satellitesSize = size.doubleValue
        }
        if let bright = satellitesBrightnessSlider {
            defaultsManager.satellitesBrightness = bright.doubleValue
        }
        if let trailingCB = satellitesTrailingCheckbox {
            defaultsManager.satellitesTrailing = (trailingCB.state == .on)
        }
        if let hl = satellitesTrailHalfLifeSlider {
            defaultsManager.satellitesTrailHalfLifeSeconds = hl.doubleValue
        }
        
        view?.settingsChanged()
        
        window?.sheetParent?.endSheet(self.window!, returnCode: .OK)
        self.window?.close()
        
        os_log("exiting saveClose", log: self.log ?? OSLog.default, type: .info)
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
        parts.append("secsBetweenClears=\(format(secsBetweenClears?.doubleValue ?? lastSecsBetweenClears))")
        parts.append("buildingHeight=\(format(buildingHeightSlider?.doubleValue ?? lastBuildingHeight))")
        parts.append("buildingFrequency=\(format(buildingFrequencySlider?.doubleValue ?? lastBuildingFrequency))")
        parts.append("debugOverlayEnabled=\(debugOverlayEnabledCheckbox?.state == .on ? "true" : "false")")
        parts.append("spawnBounds=\(shootingStarsDebugSpawnBoundsCheckbox?.state == .on ? "true" : "false")")
        parts.append("moonSizePercent=\(format(moonSizePercentSlider.doubleValue))")
        parts.append("moonBright=\(format(brightBrightnessSlider?.doubleValue ?? lastBrightBrightness))")
        parts.append("moonDark=\(format(darkBrightnessSlider?.doubleValue ?? lastDarkBrightness))")
        parts.append("moonPhaseOverrideEnabled=\(moonPhaseOverrideCheckbox?.state == .on ? "true" : "false")")
        parts.append("moonPhaseOverrideValue=\(format(moonPhaseSlider?.doubleValue ?? lastMoonPhaseOverrideValue))")
        parts.append("showLightAreaMask=\(showLightAreaTextureFillMaskCheckbox?.state == .on ? "true" : "false")")
        parts.append("shootingStarsEnabled=\(shootingStarsEnabledCheckbox.state == .on)")
        parts.append("shootingStarsAvgSeconds=\(format(shootingStarsAvgSecondsField.doubleValue))")
        if let shootingStarsDirectionPopup {
            parts.append("shootingStarsDirectionMode=\(shootingStarsDirectionPopup.indexOfSelectedItem)")
        } else {
            parts.append("shootingStarsDirectionMode=nil")
        }
        parts.append("shootingLength=\(format(lastShootingStarsLength))")
        parts.append("shootingSpeed=\(format(lastShootingStarsSpeed))")
        parts.append("shootingThickness=\(format(lastShootingStarsThickness))")
        parts.append("shootingBrightness=\(format(lastShootingStarsBrightness))")
        parts.append("shootingTrailHL=\(format(lastShootingStarsTrailHalfLifeSeconds))")
        parts.append("shootingDebugBounds=\(lastShootingStarsDebugSpawnBounds ? "true" : "false")")
        if let satellitesEnabledCheckbox {
            parts.append("satellitesEnabled=\(satellitesEnabledCheckbox.state == .on)")
        } else {
            parts.append("satellitesEnabled=nil")
        }
        parts.append("satellitesAvgSpawnSeconds=\(format(lastSatellitesAvgSpawnSeconds))")
        parts.append("satelliteSpeed=\(format(lastSatellitesSpeed))")
        parts.append("satelliteSize=\(format(lastSatellitesSize))")
        parts.append("satelliteBrightness=\(format(lastSatellitesBrightness))")
        parts.append("satelliteTrailing=\(lastSatellitesTrailing ? "true" : "false")")
        parts.append("satelliteTrailHL=\(format(lastSatellitesTrailHalfLifeSeconds))")
        return parts.joined(separator: ", ")
    }
    
    private func format(_ d: Double) -> String { String(format: "%.3f", d) }
    private func formatPhase(_ d: Double) -> String { String(format: "%.3f", d) }
}
