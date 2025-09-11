import Foundation
import Cocoa
import os
import QuartzCore
import Metal

class StarryConfigSheetController : NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let defaultsManager = StarryDefaultsManager()
    weak var view: StarryExcuseForAView?
    private var log: OSLog?
    
    // MARK: - Programmatic UI references
    
    // General section
    var starsPerSecond: NSTextField!
    var buildingLightsPerSecond: NSTextField!
    var buildingHeightSlider: NSSlider?
    var buildingHeightPreview: NSTextField?
    var buildingFrequencySlider: NSSlider?
    var buildingFrequencyPreview: NSTextField?
    var secsBetweenClears: NSTextField?
    var moonTraversalMinutes: NSTextField?
    
    // Moon section
    var moonSizePercentSlider: NSSlider!
    var moonSizePercentPreview: NSTextField!
    var brightBrightnessSlider: NSSlider?
    var brightBrightnessPreview: NSTextField?
    var darkBrightnessSlider: NSSlider?
    var darkBrightnessPreview: NSTextField?
    var moonPhaseOverrideCheckbox: NSSwitch?
    var moonPhaseSlider: NSSlider?
    var moonPhasePreview: NSTextField?
    
    // Debug toggles (main)
    var showLightAreaTextureFillMaskCheckbox: NSSwitch?
    var debugOverlayEnabledCheckbox: NSSwitch?
    
    // Shooting Stars
    var shootingStarsEnabledCheckbox: NSSwitch!
    var shootingStarsAvgSecondsField: NSTextField!
    var shootingStarsDirectionPopup: NSPopUpButton?
    var shootingStarsLengthSlider: NSSlider?
    var shootingStarsLengthPreview: NSTextField?
    var shootingStarsSpeedSlider: NSSlider?
    var shootingStarsSpeedPreview: NSTextField?
    var shootingStarsThicknessSlider: NSSlider?
    var shootingStarsThicknessPreview: NSTextField?
    var shootingStarsBrightnessSlider: NSSlider?
    var shootingStarsBrightnessPreview: NSTextField?
    var shootingStarsTrailDecaySlider: NSSlider?
    var shootingStarsTrailDecayPreview: NSTextField?
    var shootingStarsTrailHalfLifeSlider: NSSlider? { shootingStarsTrailDecaySlider }
    var shootingStarsTrailHalfLifePreview: NSTextField? { shootingStarsTrailDecayPreview }
    var shootingStarsDebugSpawnBoundsCheckbox: NSSwitch?
    
    // Satellites
    var satellitesEnabledCheckbox: NSSwitch?
    var satellitesAvgSecondsField: NSTextField?
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
    
    // Last-known cached values for change detection
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
    
    // One-time UI init flag
    private var uiInitialized = false
    
    // MARK: - Init
    
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1050),
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
    
    // MARK: - Initialization helpers
    
    private func initializeProgrammaticUIIfNeeded() {
        guard !uiInitialized, let _ = window else { return }
        uiInitialized = true
        
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "ConfigUI")
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
            os_log("Config sheet UI initialized (styleMask=0x%{public}llx)", log: log, type: .info, styleMaskRaw)
        }
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        initializeProgrammaticUIIfNeeded()
    }
    
    // MARK: - Populate defaults
    
    private func populateDefaultsAndState() {
        guard starsPerSecond != nil else { return }
        
        // Load defaults
        starsPerSecond.integerValue = Int(round(defaultsManager.starsPerSecond))
        buildingLightsPerSecond.doubleValue = defaultsManager.buildingLightsPerSecond
        
        // General
        if let bhSlider = buildingHeightSlider {
            bhSlider.doubleValue = defaultsManager.buildingHeight
            buildingHeightPreview?.stringValue = String(format: "%.3f", bhSlider.doubleValue)
        }
        if let bfSlider = buildingFrequencySlider {
            bfSlider.doubleValue = defaultsManager.buildingFrequency
            buildingFrequencyPreview?.stringValue = String(format: "%.3f", bfSlider.doubleValue)
        }
        if let secsField = secsBetweenClears {
            secsField.doubleValue = defaultsManager.secsBetweenClears
        }
        if let mtField = moonTraversalMinutes {
            mtField.integerValue = defaultsManager.moonTraversalMinutes
        }
        
        // Moon
        moonSizePercentSlider.doubleValue = defaultsManager.moonDiameterScreenWidthPercent
        moonSizePercentPreview.stringValue = String(format: "%.2f%%", moonSizePercentSlider.doubleValue * 100.0)
        if let bright = brightBrightnessSlider {
            bright.doubleValue = defaultsManager.moonBrightBrightness
            brightBrightnessPreview?.stringValue = String(format: "%.2f", bright.doubleValue)
        }
        if let dark = darkBrightnessSlider {
            dark.doubleValue = defaultsManager.moonDarkBrightness
            darkBrightnessPreview?.stringValue = String(format: "%.2f", dark.doubleValue)
        }
        if let cb = moonPhaseOverrideCheckbox {
            cb.state = defaultsManager.moonPhaseOverrideEnabled ? .on : .off
        }
        if let phaseSlider = moonPhaseSlider {
            phaseSlider.doubleValue = defaultsManager.moonPhaseOverrideValue
            moonPhasePreview?.stringValue = String(format: "%.3f", phaseSlider.doubleValue)
        }
        
        // Debug toggles
        if let showMaskCB = showLightAreaTextureFillMaskCheckbox {
            showMaskCB.state = defaultsManager.showLightAreaTextureFillMask ? .on : .off
        }
        if let debugOverlayCB = debugOverlayEnabledCheckbox {
            debugOverlayCB.state = defaultsManager.debugOverlayEnabled ? .on : .off
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
            shootingStarsBrightnessPreview?.stringValue = String(format: "%.2f", bright.doubleValue)
        }
        if let hl = shootingStarsTrailDecaySlider {
            hl.doubleValue = defaultsManager.shootingStarsTrailHalfLifeSeconds
            shootingStarsTrailDecayPreview?.stringValue = String(format: "%.3f s", hl.doubleValue)
        }
        if let spawnCB = shootingStarsDebugSpawnBoundsCheckbox {
            spawnCB.state = defaultsManager.shootingStarsDebugShowSpawnBounds ? .on : .off
        }
        
        // Satellites
        satellitesEnabledCheckbox?.state = defaultsManager.satellitesEnabled ? .on : .off
        satellitesAvgSecondsField?.doubleValue = defaultsManager.satellitesAvgSpawnSeconds
        if let sSpeed = satellitesSpeedSlider {
            sSpeed.doubleValue = defaultsManager.satellitesSpeed
            satellitesSpeedPreview?.stringValue = String(format: "%.0f", sSpeed.doubleValue)
        }
        if let sSize = satellitesSizeSlider {
            sSize.doubleValue = defaultsManager.satellitesSize
            satellitesSizePreview?.stringValue = String(format: "%.2f", sSize.doubleValue)
        }
        if let sBright = satellitesBrightnessSlider {
            sBright.doubleValue = defaultsManager.satellitesBrightness
            satellitesBrightnessPreview?.stringValue = String(format: "%.2f", sBright.doubleValue)
        }
        if let sTrail = satellitesTrailDecaySlider {
            sTrail.doubleValue = defaultsManager.satellitesTrailHalfLifeSeconds
            satellitesTrailDecayPreview?.stringValue = String(format: "%.3f s", sTrail.doubleValue)
        }
        if let sTrailEnable = satellitesTrailingCheckbox {
            sTrailEnable.state = defaultsManager.satellitesTrailing ? .on : .off
        }
        
        // Snapshot last-known
        lastStarsPerSecond = starsPerSecond.integerValue
        lastBuildingLightsPerSecond = buildingLightsPerSecond.doubleValue
        lastBuildingHeight = defaultsManager.buildingHeight
        lastBuildingFrequency = defaultsManager.buildingFrequency
        lastSecsBetweenClears = defaultsManager.secsBetweenClears
        lastMoonTraversalMinutes = defaultsManager.moonTraversalMinutes
        lastMoonSizePercent = moonSizePercentSlider.doubleValue
        lastBrightBrightness = defaultsManager.moonBrightBrightness
        lastDarkBrightness = defaultsManager.moonDarkBrightness
        lastMoonPhaseOverrideEnabled = defaultsManager.moonPhaseOverrideEnabled
        lastMoonPhaseOverrideValue = defaultsManager.moonPhaseOverrideValue
        lastShowLightAreaTextureFillMask = defaultsManager.showLightAreaTextureFillMask
        lastDebugOverlayEnabled = defaultsManager.debugOverlayEnabled
        
        lastShootingStarsEnabled = defaultsManager.shootingStarsEnabled
        lastShootingStarsAvgSeconds = defaultsManager.shootingStarsAvgSeconds
        lastShootingStarsDirectionMode = defaultsManager.shootingStarsDirectionMode
        lastShootingStarsLength = defaultsManager.shootingStarsLength
        lastShootingStarsSpeed = defaultsManager.shootingStarsSpeed
        lastShootingStarsThickness = defaultsManager.shootingStarsThickness
        lastShootingStarsBrightness = defaultsManager.shootingStarsBrightness
        lastShootingStarsTrailHalfLifeSeconds = defaultsManager.shootingStarsTrailHalfLifeSeconds
        lastShootingStarsDebugSpawnBounds = defaultsManager.shootingStarsDebugShowSpawnBounds
        
        lastSatellitesEnabled = defaultsManager.satellitesEnabled
        lastSatellitesAvgSpawnSeconds = defaultsManager.satellitesAvgSpawnSeconds
        lastSatellitesSpeed = defaultsManager.satellitesSpeed
        lastSatellitesSize = defaultsManager.satellitesSize
        lastSatellitesBrightness = defaultsManager.satellitesBrightness
        lastSatellitesTrailing = defaultsManager.satellitesTrailing
        lastSatellitesTrailHalfLifeSeconds = defaultsManager.satellitesTrailHalfLifeSeconds
        
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
        
        let leftWidth: CGFloat = 380
        
        let leftContainer = NSView()
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        
        let docView = NSView()
        docView.frame = NSRect(x: 0, y: 0, width: leftWidth, height: 1200)
        docView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = docView
        
        let sectionsStack = NSStackView()
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 18
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(sectionsStack)
        
        // Sections
        sectionsStack.addArrangedSubview(buildGeneralSection())
        sectionsStack.addArrangedSubview(buildMoonSection())
        sectionsStack.addArrangedSubview(buildShootingStarsSection())
        sectionsStack.addArrangedSubview(buildSatellitesSection())
        sectionsStack.addArrangedSubview(buildDebugSection())
        
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
        
        // Buttons Row
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
        
        // Preview view
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
        
        // Delegates
        starsPerSecond.delegate = self
        buildingLightsPerSecond.delegate = self
        shootingStarsAvgSecondsField.delegate = self
        satellitesAvgSecondsField?.delegate = self
        secsBetweenClears?.delegate = self
        moonTraversalMinutes?.delegate = self
        
        contentView.layoutSubtreeIfNeeded()
        
        if let log = log {
            os_log("buildUI completed (sections=%{public}d)", log: log, type: .info, sectionsStack.arrangedSubviews.count)
        }
    }
    
    // MARK: - Section Builders
    
    private func buildGeneralSection() -> NSView {
        let box = makeBox(title: "General")
        guard let content = box.contentView else { return box }
        let stack = makeVStack(spacing: 10)
        content.addSubview(stack)
        pinToEdges(stack, in: content, inset: 12)
        
        // Stars per second
        stack.addArrangedSubview(makeLabeledFieldRow(label: "Stars / second:",
                                                     fieldWidth: 80,
                                                     small: true) { tf in
            self.starsPerSecond = tf
        })
        
        // Building lights per second
        stack.addArrangedSubview(makeLabeledFieldRow(label: "Building lights / sec:",
                                                     fieldWidth: 80,
                                                     small: true) { tf in
            self.buildingLightsPerSecond = tf
        })
        
        // Building height slider (0..1)
        let bhRow = makeSliderRow(label: "Building height",
                                  min: 0.0, max: 1.0,
                                  format: "%.3f",
                                  action: #selector(buildingHeightChanged(_:))) { slider, preview in
            self.buildingHeightSlider = slider
            self.buildingHeightPreview = preview
        }
        stack.addArrangedSubview(bhRow)
        
        // Building frequency slider (0.001..1.0) using existing persisted range
        let bfRow = makeSliderRow(label: "Building frequency",
                                  min: 0.001, max: 1.0,
                                  format: "%.3f",
                                  action: #selector(buildingFrequencyChanged(_:))) { slider, preview in
            self.buildingFrequencySlider = slider
            self.buildingFrequencyPreview = preview
        }
        stack.addArrangedSubview(bfRow)
        
        // Seconds between clears (10..3600)
        stack.addArrangedSubview(makeLabeledFieldRow(label: "Seconds between clears:",
                                                     fieldWidth: 80,
                                                     small: true) { tf in
            self.secsBetweenClears = tf
        })
        
        // Moon traversal minutes (5..240 typical UI — underlying supports up to 720)
        stack.addArrangedSubview(makeLabeledFieldRow(label: "Moon traversal (min):",
                                                     fieldWidth: 80,
                                                     small: true) { tf in
            self.moonTraversalMinutes = tf
        })
        
        return box
    }
    
    private func buildMoonSection() -> NSView {
        let box = makeBox(title: "Moon")
        guard let content = box.contentView else { return box }
        let stack = makeVStack(spacing: 10)
        content.addSubview(stack)
        pinToEdges(stack, in: content, inset: 12)
        
        // Moon size percent slider (0.001 .. 0.25)
        let sizeRow = makeSliderRow(label: "Size (% width)",
                                    min: 0.001, max: 0.25,
                                    format: "%.3f",
                                    action: #selector(moonSliderChanged(_:))) { slider, preview in
            self.moonSizePercentSlider = slider
            self.moonSizePercentPreview = preview
        }
        stack.addArrangedSubview(sizeRow)
        
        // Bright brightness (0..1)
        let brightRow = makeSliderRow(label: "Bright brightness",
                                      min: 0.0, max: 1.0,
                                      format: "%.2f",
                                      action: #selector(moonSliderChanged(_:))) { slider, preview in
            self.brightBrightnessSlider = slider
            self.brightBrightnessPreview = preview
        }
        stack.addArrangedSubview(brightRow)
        
        // Dark brightness (0..1)
        let darkRow = makeSliderRow(label: "Dark brightness",
                                    min: 0.0, max: 1.0,
                                    format: "%.2f",
                                    action: #selector(moonSliderChanged(_:))) { slider, preview in
            self.darkBrightnessSlider = slider
            self.darkBrightnessPreview = preview
        }
        stack.addArrangedSubview(darkRow)
        
        // Phase override
        let phaseToggleRow = makeCheckboxRow(label: "Override phase") { sw in
            self.moonPhaseOverrideCheckbox = sw
            sw.target = self
            sw.action = #selector(moonPhaseOverrideToggled(_:))
        }
        stack.addArrangedSubview(phaseToggleRow)
        
        let phaseSliderRow = makeSliderRow(label: "Phase (0..1)",
                                           min: 0.0, max: 1.0,
                                           format: "%.3f",
                                           action: #selector(moonPhaseSliderChanged(_:))) { slider, preview in
            self.moonPhaseSlider = slider
            self.moonPhasePreview = preview
        }
        stack.addArrangedSubview(phaseSliderRow)
        
        return box
    }
    
    private func buildShootingStarsSection() -> NSView {
        let box = makeBox(title: "Shooting Stars")
        guard let content = box.contentView else { return box }
        let stack = makeVStack(spacing: 10)
        content.addSubview(stack)
        pinToEdges(stack, in: content, inset: 12)
        
        // Enable checkbox
        let enableRow = makeCheckboxRow(label: "Enable shooting stars") { sw in
            self.shootingStarsEnabledCheckbox = sw
            sw.target = self
            sw.action = #selector(shootingStarsToggled(_:))
        }
        stack.addArrangedSubview(enableRow)
        
        // Avg seconds between stars
        stack.addArrangedSubview(makeLabeledFieldRow(label: "Avg seconds:",
                                                     fieldWidth: 80,
                                                     small: true) { tf in
            self.shootingStarsAvgSecondsField = tf
            tf.target = self
            tf.action = #selector(shootingStarsAvgSecondsChanged(_:))
        })
        
        // Direction popup
        let directionRow = NSStackView()
        directionRow.orientation = .horizontal
        directionRow.alignment = .centerY
        directionRow.spacing = 6
        directionRow.translatesAutoresizingMaskIntoConstraints = false
        let dirLabel = makeLabel("Direction:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: [
            "Random",
            "Left → Right",
            "Right → Left",
            "TL → BR",
            "TR → BL"
        ])
        popup.target = self
        popup.action = #selector(shootingStarsDirectionChanged(_:))
        shootingStarsDirectionPopup = popup
        directionRow.addArrangedSubview(dirLabel)
        directionRow.addArrangedSubview(popup)
        stack.addArrangedSubview(directionRow)
        
        // Length (40..300)
        stack.addArrangedSubview(makeSliderRow(label: "Length",
                                               min: 40, max: 300,
                                               format: "%.0f",
                                               action: #selector(shootingStarsSliderChanged(_:))) { slider, preview in
            self.shootingStarsLengthSlider = slider
            self.shootingStarsLengthPreview = preview
        })
        
        // Speed (200..1200)
        stack.addArrangedSubview(makeSliderRow(label: "Speed",
                                               min: 200, max: 1200,
                                               format: "%.0f",
                                               action: #selector(shootingStarsSliderChanged(_:))) { slider, preview in
            self.shootingStarsSpeedSlider = slider
            self.shootingStarsSpeedPreview = preview
        })
        
        // Thickness (1..4)
        stack.addArrangedSubview(makeSliderRow(label: "Thickness",
                                               min: 1, max: 4,
                                               format: "%.2f",
                                               action: #selector(shootingStarsSliderChanged(_:))) { slider, preview in
            self.shootingStarsThicknessSlider = slider
            self.shootingStarsThicknessPreview = preview
        })
        
        // Brightness (0.3..1.0)
        stack.addArrangedSubview(makeSliderRow(label: "Brightness",
                                               min: 0.3, max: 1.0,
                                               format: "%.2f",
                                               action: #selector(shootingStarsSliderChanged(_:))) { slider, preview in
            self.shootingStarsBrightnessSlider = slider
            self.shootingStarsBrightnessPreview = preview
        })
        
        // Trail half-life (0.01..2.0)
        stack.addArrangedSubview(makeSliderRow(label: "Trail half-life (s)",
                                               min: 0.01, max: 2.0,
                                               format: "%.3f",
                                               action: #selector(shootingStarsSliderChanged(_:))) { slider, preview in
            self.shootingStarsTrailDecaySlider = slider
            self.shootingStarsTrailDecayPreview = preview
        })
        
        // Debug spawn bounds
        stack.addArrangedSubview(makeCheckboxRow(label: "Show spawn bounds (debug)") { sw in
            self.shootingStarsDebugSpawnBoundsCheckbox = sw
            sw.target = self
            sw.action = #selector(shootingStarsDebugSpawnBoundsToggled(_:))
        })
        
        return box
    }
    
    private func buildSatellitesSection() -> NSView {
        let box = makeBox(title: "Satellites")
        guard let content = box.contentView else { return box }
        let stack = makeVStack(spacing: 10)
        content.addSubview(stack)
        pinToEdges(stack, in: content, inset: 12)
        
        // Enable
        stack.addArrangedSubview(makeCheckboxRow(label: "Enable satellites") { sw in
            self.satellitesEnabledCheckbox = sw
            sw.target = self
            sw.action = #selector(satellitesToggled(_:))
        })
        
        // Avg seconds field
        stack.addArrangedSubview(makeLabeledFieldRow(label: "Avg seconds:",
                                                     fieldWidth: 80,
                                                     small: true) { tf in
            self.satellitesAvgSecondsField = tf
            tf.target = self
            tf.action = #selector(satellitesAvgSecondsChanged(_:))
        })
        
        // Speed (10..600)
        stack.addArrangedSubview(makeSliderRow(label: "Speed",
                                               min: 10, max: 600,
                                               format: "%.0f",
                                               action: #selector(satellitesSliderChanged(_:))) { slider, preview in
            self.satellitesSpeedSlider = slider
            self.satellitesSpeedPreview = preview
        })
        
        // Size (1..6)
        stack.addArrangedSubview(makeSliderRow(label: "Size",
                                               min: 1, max: 6,
                                               format: "%.2f",
                                               action: #selector(satellitesSliderChanged(_:))) { slider, preview in
            self.satellitesSizeSlider = slider
            self.satellitesSizePreview = preview
        })
        
        // Brightness (0.2..1.2)
        stack.addArrangedSubview(makeSliderRow(label: "Brightness",
                                               min: 0.2, max: 1.2,
                                               format: "%.2f",
                                               action: #selector(satellitesSliderChanged(_:))) { slider, preview in
            self.satellitesBrightnessSlider = slider
            self.satellitesBrightnessPreview = preview
        })
        
        // Trail half-life (0.01..2.0)
        stack.addArrangedSubview(makeSliderRow(label: "Trail half-life (s)",
                                               min: 0.01, max: 2.0,
                                               format: "%.3f",
                                               action: #selector(satellitesSliderChanged(_:))) { slider, preview in
            self.satellitesTrailDecaySlider = slider
            self.satellitesTrailDecayPreview = preview
        })
        
        // Trailing enable
        stack.addArrangedSubview(makeCheckboxRow(label: "Enable trailing") { sw in
            self.satellitesTrailingCheckbox = sw
            sw.target = self
            sw.action = #selector(satellitesTrailingToggled(_:))
        })
        
        return box
    }
    
    private func buildDebugSection() -> NSView {
        let box = makeBox(title: "Debug / Diagnostics")
        guard let content = box.contentView else { return box }
        let stack = makeVStack(spacing: 10)
        content.addSubview(stack)
        pinToEdges(stack, in: content, inset: 12)
        
        stack.addArrangedSubview(makeCheckboxRow(label: "Show light area texture fill mask") { sw in
            self.showLightAreaTextureFillMaskCheckbox = sw
            sw.target = self
            sw.action = #selector(showLightAreaTextureFillMaskToggled(_:))
        })
        stack.addArrangedSubview(makeCheckboxRow(label: "Debug overlay") { sw in
            self.debugOverlayEnabledCheckbox = sw
            sw.target = self
            sw.action = #selector(debugOverlayToggled(_:))
        })
        
        return box
    }
    
    // MARK: - Builders / Helpers
    
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
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        
        let lbl = makeLabel(label)
        if small {
            lbl.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }
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
        row.addArrangedSubview(tf)
        bindField(tf)
        return row
    }
    
    private func makeSliderRow(label: String,
                               min: Double,
                               max: Double,
                               format: String,
                               action: Selector,
                               bind: (NSSlider, NSTextField) -> Void) -> NSStackView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        
        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false
        let lbl = makeLabel(label)
        let preview = makeSmallLabel("--")
        top.addArrangedSubview(lbl)
        top.addArrangedSubview(preview)
        
        let slider = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: action)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        slider.isContinuous = true
        
        row.addArrangedSubview(top)
        row.addArrangedSubview(slider)
        bind(slider, preview)
        return row
    }
    
    private func makeCheckboxRow(label: String,
                                 bind: (NSSwitch) -> Void) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY