import Cocoa
import ScreenSaver
import QuartzCore

// ---------------------------------------------------------------------------
// StarryConfigPanel
//
// Programmatic options sheet for the Rust/wgpu Starry Night screensaver.
// No dependency on the legacy Swift implementation.
//
// Usage:
//   private lazy var configController = StarryConfigPanel()
//   override var hasConfigureSheet: Bool { true }
//   override var configureSheet: NSWindow? { configController.window }
// ---------------------------------------------------------------------------

final class StarryConfigPanel: NSObject {

    let window: NSWindow
    private let dm = RustDefaultsManager()

    // Called (debounced ~350 ms) on every control change so the running
    // engine can be recreated with the new settings without persisting to defaults.
    var onLiveChange: ((String) -> Void)?
    private var liveUpdateItem: DispatchWorkItem?

    // MARK: - In-panel preview
    private var previewView: NSView?
    private var previewMetalLayer: CAMetalLayer?
    private var previewHandle: UnsafeMutableRawPointer?
    private var previewTimer: Timer?

    // MARK: - Sky controls
    private let starsSlider       = NSSlider()
    private let starsLabel        = NSTextField(labelWithString: "")
    private let lightsSlider      = NSSlider()
    private let lightsLabel       = NSTextField(labelWithString: "")
    private let clearSlider       = NSSlider()
    private let clearLabel        = NSTextField(labelWithString: "")
    private let buildingHtSlider  = NSSlider()
    private let buildingHtLabel   = NSTextField(labelWithString: "")

    // MARK: - Effects controls
    private let shootEnabledBox   = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let shootAvgSlider    = NSSlider()
    private let shootAvgLabel     = NSTextField(labelWithString: "")
    private let satEnabledBox     = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)

    // MARK: - Moon controls
    private let moonEnabledBox    = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let moonSizeSlider    = NSSlider()
    private let moonSizeLabel     = NSTextField(labelWithString: "")
    private let moonTravSlider    = NSSlider()
    private let moonTravLabel     = NSTextField(labelWithString: "")
    private let moonTermPopup     = NSPopUpButton()
    private let moonBrightSlider  = NSSlider()
    private let moonBrightLabel   = NSTextField(labelWithString: "")
    private let moonDarkSlider    = NSSlider()
    private let moonDarkLabel     = NSTextField(labelWithString: "")
    private let moonPhaseOverBox  = NSButton(checkboxWithTitle: "Override phase", target: nil, action: nil)
    private let moonPhaseSlider   = NSSlider()
    private let moonPhaseLabel    = NSTextField(labelWithString: "")

    // MARK: - Planet controls
    private let planetsEnabledBox = NSButton(checkboxWithTitle: "Planets enabled", target: nil, action: nil)
    private let moonsEnabledBox   = NSButton(checkboxWithTitle: "Planet moons enabled (Galilean + Titan)", target: nil, action: nil)
    private let horizBehavPopup   = NSPopUpButton()
    private let phaseModePopup    = NSPopUpButton()
    private let ringStylePopup    = NSPopUpButton()
    private let mercurySlider     = NSSlider()
    private let mercuryLabel      = NSTextField(labelWithString: "")
    private let venusSlider       = NSSlider()
    private let venusLabel        = NSTextField(labelWithString: "")
    private let marsSlider        = NSSlider()
    private let marsLabel         = NSTextField(labelWithString: "")
    private let jupiterSlider     = NSSlider()
    private let jupiterLabel      = NSTextField(labelWithString: "")
    private let saturnSlider      = NSSlider()
    private let saturnLabel       = NSTextField(labelWithString: "")
    private let uranusSlider      = NSSlider()
    private let uranusLabel       = NSTextField(labelWithString: "")
    private let neptuneSlider     = NSSlider()
    private let neptuneLabel      = NSTextField(labelWithString: "")
    private let plutoSlider       = NSSlider()
    private let plutoLabel        = NSTextField(labelWithString: "")

    // MARK: - Debug controls
    private let debugOverlayBox   = NSButton(checkboxWithTitle: "Show FPS / CPU overlay", target: nil, action: nil)
    private let debugMoonBox      = NSButton(checkboxWithTitle: "Debug moon colors (raw albedo)", target: nil, action: nil)

    // MARK: - Init

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing:  .buffered,
            defer:    false
        )
        window.title = "Starry Night (Rust) Options"
        super.init()
        window.delegate = self
        buildUI()
        loadFromDefaults()
    }

    // MARK: - UI construction

    private func buildUI() {
        let cv = window.contentView!
        let leftWidth: CGFloat = 380

        // --- Left pane: tabs + OK/Cancel ---
        let left = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        tabs.addTabViewItem(makeTab("Sky",     skyContent()))
        tabs.addTabViewItem(makeTab("Effects", effectsContent()))
        tabs.addTabViewItem(makeTab("Moon",    moonContent()))
        tabs.addTabViewItem(makeTab("Planets", planetsContent()))
        tabs.addTabViewItem(makeTab("Debug",   debugContent()))

        let ok = NSButton(title: "OK", target: self, action: #selector(okTapped))
        ok.translatesAutoresizingMaskIntoConstraints = false
        ok.keyEquivalent = "\r"

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.keyEquivalent = "\u{1b}"

        left.addSubview(tabs)
        left.addSubview(ok)
        left.addSubview(cancel)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: left.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -8),
            tabs.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -10),

            ok.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            ok.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -12),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            cancel.trailingAnchor.constraint(equalTo: ok.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: ok.centerYAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        // --- Separator ---
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // --- Right pane: live preview ---
        let pv = NSView()
        pv.wantsLayer = true
        pv.translatesAutoresizingMaskIntoConstraints = false
        pv.layer?.backgroundColor = NSColor.black.cgColor
        previewView = pv

        // Label underneath the preview
        let hint = NSTextField(labelWithString: "Preview (reflects changes after ~0.35 s)")
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.alignment = .center

        cv.addSubview(left)
        cv.addSubview(sep)
        cv.addSubview(pv)
        cv.addSubview(hint)

        NSLayoutConstraint.activate([
            // left pane
            left.topAnchor.constraint(equalTo: cv.topAnchor),
            left.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            left.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: leftWidth),

            // separator
            sep.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            sep.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            sep.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),

            // preview pane (fills remaining width, leaving room for hint)
            pv.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            pv.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 10),
            pv.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -10),
            pv.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            hint.leadingAnchor.constraint(equalTo: pv.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: pv.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
        ])
    }

    private func makeTab(_ label: String, _ content: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = label
        item.view = content
        return item
    }

    // MARK: - Tab content builders

    private func skyContent() -> NSView {
        configureSlider(starsSlider,    min: 0, max: 1,    target: self, action: #selector(skyChanged))
        configureSlider(lightsSlider,   min: 0, max: 1,    target: self, action: #selector(skyChanged))
        configureSlider(clearSlider,    min: 1, max: 3600, target: self, action: #selector(skyChanged))
        configureSlider(buildingHtSlider, min: 0, max: 1,  target: self, action: #selector(skyChanged))

        return vstack([
            row("Star density",           starsSlider,      starsLabel),
            row("Building lights",        lightsSlider,     lightsLabel),
            row("Clear interval (s)",     clearSlider,      clearLabel),
            row("Max building height",    buildingHtSlider, buildingHtLabel),
        ])
    }

    private func effectsContent() -> NSView {
        shootEnabledBox.target = self
        shootEnabledBox.action = #selector(effectsChanged)
        configureSlider(shootAvgSlider, min: 0.5, max: 120, target: self, action: #selector(effectsChanged))
        satEnabledBox.target = self
        satEnabledBox.action = #selector(effectsChanged)

        return vstack([
            sectionLabel("Shooting Stars"),
            indentRow(shootEnabledBox),
            row("Avg seconds between",   shootAvgSlider,   shootAvgLabel),
            sectionLabel("Satellites"),
            indentRow(satEnabledBox),
        ])
    }

    private func moonContent() -> NSView {
        moonEnabledBox.target = self
        moonEnabledBox.action = #selector(moonChanged)

        configureSlider(moonSizeSlider,   min: 0.001, max: 0.25,   target: self, action: #selector(moonChanged))
        configureSlider(moonTravSlider,   min: 60,    max: 43200,  target: self, action: #selector(moonChanged))
        configureSlider(moonBrightSlider, min: 0.2,   max: 1.2,    target: self, action: #selector(moonChanged))
        configureSlider(moonDarkSlider,   min: 0,     max: 0.9,    target: self, action: #selector(moonChanged))
        configureSlider(moonPhaseSlider,  min: 0,     max: 1,      target: self, action: #selector(moonChanged))

        moonTermPopup.addItems(withTitles: ["Hard", "Smooth", "Banded"])
        moonTermPopup.target = self
        moonTermPopup.action = #selector(moonChanged)

        moonPhaseOverBox.target = self
        moonPhaseOverBox.action = #selector(moonChanged)

        return vstack([
            indentRow(moonEnabledBox),
            row("Moon size (% width)",   moonSizeSlider,   moonSizeLabel),
            row("Traversal time (min)",  moonTravSlider,   moonTravLabel),
            row("Terminator mode",       moonTermPopup,    nil),
            row("Lit brightness",        moonBrightSlider, moonBrightLabel),
            row("Dark brightness",       moonDarkSlider,   moonDarkLabel),
            indentRow(moonPhaseOverBox),
            row("Phase override value",  moonPhaseSlider,  moonPhaseLabel),
        ])
    }

    private func planetsContent() -> NSView {
        planetsEnabledBox.target = self
        planetsEnabledBox.action = #selector(planetsChanged)
        moonsEnabledBox.target = self
        moonsEnabledBox.action = #selector(planetsChanged)

        horizBehavPopup.addItems(withTitles: ["Hide when below horizon",
                                              "Always random position",
                                              "Random when below horizon"])
        horizBehavPopup.target = self
        horizBehavPopup.action = #selector(planetsChanged)

        phaseModePopup.addItems(withTitles: ["Forced full (fully lit)",
                                              "Forced half (half-lit)",
                                              "Computed (astronomical)"])
        phaseModePopup.target = self
        phaseModePopup.action = #selector(planetsChanged)

        ringStylePopup.addItems(withTitles: ["Smooth", "Flat Retro", "Chunky Pixel"])
        ringStylePopup.target = self
        ringStylePopup.action = #selector(planetsChanged)

        let sizeMax = 0.2
        for (sl, lbl) in [(mercurySlider, mercuryLabel), (venusSlider, venusLabel),
                          (marsSlider, marsLabel),    (jupiterSlider, jupiterLabel),
                          (saturnSlider, saturnLabel), (uranusSlider, uranusLabel),
                          (neptuneSlider, neptuneLabel), (plutoSlider, plutoLabel)] {
            configureSlider(sl, min: 0, max: sizeMax, target: self, action: #selector(planetsChanged))
            _ = lbl
        }

        return vstack([
            indentRow(planetsEnabledBox),
            indentRow(moonsEnabledBox),
            row("Below-horizon",         horizBehavPopup,   nil),
            row("Phase mode",            phaseModePopup,    nil),
            row("Saturn rings",          ringStylePopup,    nil),
            sectionLabel("Planet Sizes (fraction of screen width)"),
            row("Mercury",  mercurySlider, mercuryLabel),
            row("Venus",    venusSlider,   venusLabel),
            row("Mars",     marsSlider,    marsLabel),
            row("Jupiter",  jupiterSlider, jupiterLabel),
            row("Saturn",   saturnSlider,  saturnLabel),
            row("Uranus",   uranusSlider,  uranusLabel),
            row("Neptune",  neptuneSlider, neptuneLabel),
            row("Pluto",    plutoSlider,   plutoLabel),
        ])
    }

    private func debugContent() -> NSView {
        debugOverlayBox.target = self
        debugOverlayBox.action = #selector(debugChanged)
        debugMoonBox.target = self
        debugMoonBox.action = #selector(debugChanged)

        return vstack([
            indentRow(debugOverlayBox),
            indentRow(debugMoonBox),
        ])
    }

    // MARK: - Layout helpers

    private func vstack(_ views: [NSView]) -> NSView {
        let sv = NSStackView(views: views)
        sv.orientation = .vertical
        sv.alignment   = .leading
        sv.spacing     = 8
        sv.edgeInsets  = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }

    private func row(_ labelText: String, _ control: NSView, _ valueLabel: NSTextField?) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        lbl.widthAnchor.constraint(equalToConstant: 160).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = [lbl, control]
        if let vl = valueLabel {
            vl.translatesAutoresizingMaskIntoConstraints = false
            vl.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            vl.alignment = .right
            vl.widthAnchor.constraint(equalToConstant: 56).isActive = true
            arranged.append(vl)
        }

        let sv = NSStackView(views: arranged)
        sv.orientation = .horizontal
        sv.spacing = 8
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }

    private func indentRow(_ control: NSView) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        let sv = NSStackView(views: [control])
        sv.orientation = .horizontal
        sv.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }

    private func sectionLabel(_ text: String) -> NSView {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        lbl.textColor = .secondaryLabelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
    }

    private func configureSlider(_ s: NSSlider, min: Double, max: Double,
                                  target: AnyObject, action: Selector) {
        s.minValue = min
        s.maxValue = max
        s.isContinuous = true
        s.target = target
        s.action = action
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    }

    // MARK: - Load / Save

    private func loadFromDefaults() {
        starsSlider.doubleValue      = dm.starsFraction
        lightsSlider.doubleValue     = dm.lightsFraction
        clearSlider.doubleValue      = dm.clearIntervalS
        buildingHtSlider.doubleValue = dm.buildingHeightPctMax

        shootEnabledBox.state = dm.shootingStarsEnabled ? .on : .off
        shootAvgSlider.doubleValue = dm.shootingStarsAvgSeconds
        satEnabledBox.state = dm.satellitesEnabled ? .on : .off

        moonEnabledBox.state = dm.moonEnabled ? .on : .off
        moonSizeSlider.doubleValue   = dm.moonDiameterPercent
        moonTravSlider.doubleValue   = dm.moonTraversalSeconds
        moonTermPopup.selectItem(at: dm.moonTerminatorMode)
        moonBrightSlider.doubleValue = dm.moonBrightBrightness
        moonDarkSlider.doubleValue   = dm.moonDarkBrightness
        moonPhaseOverBox.state = dm.moonPhaseOverrideEnabled ? .on : .off
        moonPhaseSlider.doubleValue  = dm.moonPhaseOverrideValue

        planetsEnabledBox.state = dm.planetsEnabled ? .on : .off
        moonsEnabledBox.state   = dm.planetMoonsEnabled ? .on : .off
        let horizIdx: Int
        switch dm.planetBelowHorizonBehavior {
        case "random":            horizIdx = 1
        case "random-when-below": horizIdx = 2
        default:                  horizIdx = 0
        }
        horizBehavPopup.selectItem(at: horizIdx)
        let phaseIdx: Int
        switch dm.planetPhaseMode {
        case "forced-half": phaseIdx = 1
        case "computed":    phaseIdx = 2
        default:            phaseIdx = 0
        }
        phaseModePopup.selectItem(at: phaseIdx)
        let ringIdx: Int
        switch dm.saturnRingStyle {
        case "smooth":       ringIdx = 0
        case "chunky-pixel": ringIdx = 2
        default:             ringIdx = 1
        }
        ringStylePopup.selectItem(at: ringIdx)

        mercurySlider.doubleValue = dm.mercurySize
        venusSlider.doubleValue   = dm.venusSize
        marsSlider.doubleValue    = dm.marsSize
        jupiterSlider.doubleValue = dm.jupiterSize
        saturnSlider.doubleValue  = dm.saturnSize
        uranusSlider.doubleValue  = dm.uranusSize
        neptuneSlider.doubleValue = dm.neptuneSize
        plutoSlider.doubleValue   = dm.plutoSize

        debugOverlayBox.state = dm.debugOverlayEnabled ? .on : .off
        debugMoonBox.state    = dm.debugMoonColors ? .on : .off

        refreshValueLabels()
    }

    private func saveToDefaults() {
        dm.starsFraction            = starsSlider.doubleValue
        dm.lightsFraction           = lightsSlider.doubleValue
        dm.clearIntervalS           = clearSlider.doubleValue
        dm.buildingHeightPctMax     = buildingHtSlider.doubleValue
        dm.shootingStarsEnabled     = shootEnabledBox.state == .on
        dm.shootingStarsAvgSeconds  = shootAvgSlider.doubleValue
        dm.satellitesEnabled        = satEnabledBox.state == .on
        dm.moonEnabled              = moonEnabledBox.state == .on
        dm.moonDiameterPercent      = moonSizeSlider.doubleValue
        dm.moonTraversalSeconds     = moonTravSlider.doubleValue
        dm.moonTerminatorMode       = moonTermPopup.indexOfSelectedItem
        dm.moonBrightBrightness     = moonBrightSlider.doubleValue
        dm.moonDarkBrightness       = moonDarkSlider.doubleValue
        dm.moonPhaseOverrideEnabled = moonPhaseOverBox.state == .on
        dm.moonPhaseOverrideValue   = moonPhaseSlider.doubleValue
        dm.planetsEnabled           = planetsEnabledBox.state == .on
        dm.planetMoonsEnabled       = moonsEnabledBox.state == .on

        let horizValues = ["hide", "random", "random-when-below"]
        dm.planetBelowHorizonBehavior = horizValues[safe: horizBehavPopup.indexOfSelectedItem] ?? "hide"
        let phaseValues = ["forced-full", "forced-half", "computed"]
        dm.planetPhaseMode = phaseValues[safe: phaseModePopup.indexOfSelectedItem] ?? "computed"
        let ringValues = ["smooth", "flat-retro", "chunky-pixel"]
        dm.saturnRingStyle = ringValues[safe: ringStylePopup.indexOfSelectedItem] ?? "flat-retro"

        dm.mercurySize = mercurySlider.doubleValue
        dm.venusSize   = venusSlider.doubleValue
        dm.marsSize    = marsSlider.doubleValue
        dm.jupiterSize = jupiterSlider.doubleValue
        dm.saturnSize  = saturnSlider.doubleValue
        dm.uranusSize  = uranusSlider.doubleValue
        dm.neptuneSize = neptuneSlider.doubleValue
        dm.plutoSize   = plutoSlider.doubleValue

        dm.debugOverlayEnabled = debugOverlayBox.state == .on
        dm.debugMoonColors     = debugMoonBox.state == .on
    }

    // MARK: - Value label refresh

    private func refreshValueLabels() {
        starsLabel.stringValue      = String(format: "%.2f", starsSlider.doubleValue)
        lightsLabel.stringValue     = String(format: "%.2f", lightsSlider.doubleValue)
        clearLabel.stringValue      = String(format: "%.0fs", clearSlider.doubleValue)
        buildingHtLabel.stringValue = String(format: "%.2f", buildingHtSlider.doubleValue)

        shootAvgLabel.stringValue   = String(format: "%.1fs", shootAvgSlider.doubleValue)

        moonSizeLabel.stringValue   = String(format: "%.1f%%", moonSizeSlider.doubleValue * 100)
        moonTravLabel.stringValue   = String(format: "%.0fm", moonTravSlider.doubleValue / 60)
        moonBrightLabel.stringValue = String(format: "%.2f", moonBrightSlider.doubleValue)
        moonDarkLabel.stringValue   = String(format: "%.2f", moonDarkSlider.doubleValue)
        moonPhaseLabel.stringValue  = String(format: "%.2f", moonPhaseSlider.doubleValue)

        let pct = { (v: Double) in String(format: "%.3f%%", v * 100) }
        mercuryLabel.stringValue = pct(mercurySlider.doubleValue)
        venusLabel.stringValue   = pct(venusSlider.doubleValue)
        marsLabel.stringValue    = pct(marsSlider.doubleValue)
        jupiterLabel.stringValue = pct(jupiterSlider.doubleValue)
        saturnLabel.stringValue  = pct(saturnSlider.doubleValue)
        uranusLabel.stringValue  = pct(uranusSlider.doubleValue)
        neptuneLabel.stringValue = pct(neptuneSlider.doubleValue)
        plutoLabel.stringValue   = pct(plutoSlider.doubleValue)
    }

    // MARK: - Actions

    @objc private func skyChanged(_: Any?)      { refreshValueLabels(); scheduleLiveUpdate() }
    @objc private func effectsChanged(_: Any?)  { refreshValueLabels(); scheduleLiveUpdate() }
    @objc private func moonChanged(_: Any?)     { refreshValueLabels(); scheduleLiveUpdate() }
    @objc private func planetsChanged(_: Any?)  { refreshValueLabels(); scheduleLiveUpdate() }
    @objc private func debugChanged(_: Any?)    { scheduleLiveUpdate() }

    private func scheduleLiveUpdate() {
        liveUpdateItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let toml = self.currentTomlString()
            self.onLiveChange?(toml)
            self.rebuildPreviewEngine(toml: toml)
        }
        liveUpdateItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    // MARK: - Preview engine lifecycle

    private func startPreview() {
        guard let pv = previewView, previewMetalLayer == nil else { return }
        pv.wantsLayer = true
        // Defer one run-loop cycle so the view is fully laid out.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let pv = self.previewView else { return }
            let scale = pv.window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let mLayer = CAMetalLayer()
            mLayer.frame = pv.bounds
            mLayer.contentsScale = scale
            mLayer.isOpaque = true
            pv.layer?.addSublayer(mLayer)
            self.previewMetalLayer = mLayer
            self.rebuildPreviewEngine(toml: RustDefaultsManager().tomlString())
            // Observe frame changes on pv so we can sync mLayer + Rust engine
            // after Auto Layout finishes (windowDidResize fires *before* layout).
            pv.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.previewViewFrameChanged(_:)),
                name: NSView.frameDidChangeNotification,
                object: pv
            )
            self.previewTimer = Timer.scheduledTimer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(self.previewTick),
                userInfo: nil,
                repeats: true
            )
        }
    }

    private func stopPreview() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.frameDidChangeNotification,
            object: previewView
        )
        previewTimer?.invalidate()
        previewTimer = nil
        if let h = previewHandle {
            starry_destroy(h)
            previewHandle = nil
        }
        previewMetalLayer?.removeFromSuperlayer()
        previewMetalLayer = nil
    }

    @objc private func previewViewFrameChanged(_ notification: Notification) {
        guard let pv = previewView, let mLayer = previewMetalLayer, let h = previewHandle else { return }
        let scale = pv.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        mLayer.frame = pv.bounds
        let w  = UInt32(max(pv.bounds.width  * scale, 1))
        let hp = UInt32(max(pv.bounds.height * scale, 1))
        starry_resize(h, w, hp)
    }

    private func rebuildPreviewEngine(toml: String) {
        guard let pv = previewView, let mLayer = previewMetalLayer else { return }
        if let h = previewHandle {
            starry_destroy(h)
            previewHandle = nil
        }
        let scale = pv.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0
        mLayer.frame = pv.bounds
        let w = UInt32(max(pv.bounds.width  * scale, 1))
        let h = UInt32(max(pv.bounds.height * scale, 1))
        previewHandle = toml.withCString { ptr in
            starry_create_with_toml(
                Unmanaged.passUnretained(mLayer).toOpaque(), w, h, ptr
            )
        }
    }

    @objc private func previewTick() {
        guard let h = previewHandle else { return }
        starry_frame(h)
    }

    // Serialises the current UI control state to TOML without touching saved defaults.
    // Key names and format must match PartialConfig in toml_config.rs exactly.
    func currentTomlString() -> String {
        var lines: [String] = []
        func f(_ key: String, _ v: Double) { lines.append("\(key) = \(v)") }
        func b(_ key: String, _ v: Bool)   { lines.append("\(key) = \(v)") }
        func i(_ key: String, _ v: Int)    { lines.append("\(key) = \(v)") }
        func q(_ key: String, _ v: String) { lines.append("\(key) = \"\(v)\"") }

        f("stars_fraction",             starsSlider.doubleValue)
        f("lights_fraction",            lightsSlider.doubleValue)
        f("clear_interval_s",           clearSlider.doubleValue)
        f("building_height_pct_max",    buildingHtSlider.doubleValue)
        b("shooting_stars_enabled",     shootEnabledBox.state == .on)
        f("shooting_stars_avg_seconds", shootAvgSlider.doubleValue)
        b("satellites_enabled",         satEnabledBox.state == .on)
        b("moon_enabled",               moonEnabledBox.state == .on)
        f("moon_diameter_percent",      moonSizeSlider.doubleValue)
        f("moon_traversal_seconds",     moonTravSlider.doubleValue)
        i("moon_terminator_mode",       moonTermPopup.indexOfSelectedItem)
        f("moon_bright_brightness",     moonBrightSlider.doubleValue)
        f("moon_dark_brightness",       moonDarkSlider.doubleValue)
        b("moon_phase_override_enabled", moonPhaseOverBox.state == .on)
        f("moon_phase_override_value",  moonPhaseSlider.doubleValue)
        b("planets_enabled",            planetsEnabledBox.state == .on)
        b("planet_moons_enabled",       moonsEnabledBox.state == .on)
        let horizValues = ["hide", "random", "random-when-below"]
        q("planet_below_horizon_behavior", horizValues[safe: horizBehavPopup.indexOfSelectedItem] ?? "hide")
        let phaseValues = ["forced-full", "forced-half", "computed"]
        q("planet_phase_mode",          phaseValues[safe: phaseModePopup.indexOfSelectedItem] ?? "computed")
        let ringValues = ["smooth", "flat-retro", "chunky-pixel"]
        q("saturn_ring_style",          ringValues[safe: ringStylePopup.indexOfSelectedItem] ?? "flat-retro")
        f("mercury_size",               mercurySlider.doubleValue)
        f("venus_size",                 venusSlider.doubleValue)
        f("mars_size",                  marsSlider.doubleValue)
        f("jupiter_size",               jupiterSlider.doubleValue)
        f("saturn_size",                saturnSlider.doubleValue)
        f("uranus_size",                uranusSlider.doubleValue)
        f("neptune_size",               neptuneSlider.doubleValue)
        f("pluto_size",                 plutoSlider.doubleValue)
        b("debug_overlay_enabled",      debugOverlayBox.state == .on)
        b("debug_moon_colors",          debugMoonBox.state == .on)
        return lines.joined(separator: "\n")
    }

    @objc private func okTapped(_: Any?) {
        saveToDefaults()
        stopPreview()
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }

    @objc private func cancelTapped(_: Any?) {
        stopPreview()
        window.sheetParent?.endSheet(window, returnCode: .cancel)
    }
}

// MARK: - NSWindowDelegate (preview lifecycle)

extension StarryConfigPanel: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        startPreview()
    }

    func windowWillClose(_ notification: Notification) {
        stopPreview()
    }

}

// MARK: - Array safe subscript helper (local to this file)

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
