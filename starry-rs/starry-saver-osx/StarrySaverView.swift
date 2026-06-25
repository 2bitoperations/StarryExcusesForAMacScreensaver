import ScreenSaver
import QuartzCore
import os.log

// ---------------------------------------------------------------------------
// C FFI declarations — resolved at load time from libstarry_saver.dylib
// which is embedded in Contents/Frameworks/ and located via the rpath
// @loader_path/../Frameworks baked in by build-saver.sh.
// ---------------------------------------------------------------------------

@_silgen_name("starry_create")
private func starry_create(
    _ layer: UnsafeMutableRawPointer,
    _ width: UInt32,
    _ height: UInt32
) -> UnsafeMutableRawPointer?

@_silgen_name("starry_frame")
private func starry_frame(_ handle: UnsafeMutableRawPointer)

@_silgen_name("starry_resize")
private func starry_resize(
    _ handle: UnsafeMutableRawPointer,
    _ width: UInt32,
    _ height: UInt32
)

@_silgen_name("starry_destroy")
private func starry_destroy(_ handle: UnsafeMutableRawPointer)

// ---------------------------------------------------------------------------

private let log = Logger(
    subsystem: "com.2bitoperations.screensaver.StarryNightRust",
    category: "StarrySaverView"
)

// @objc(StarrySaverView) pins the Objective-C runtime name to the bare
// class name so NSPrincipalClass = "StarrySaverView" in Info.plist works
// regardless of the Swift module name.
@objc(StarrySaverView)
class StarrySaverView: ScreenSaverView {
    private var renderHandle: UnsafeMutableRawPointer?

    // Lazy so the panel is created on demand and lives for the view's lifetime.
    private lazy var configPanel: NSWindow = makeConfigPanel()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        animationTimeInterval = 1.0 / 60.0
        log.info("init \(Int(frame.width))×\(Int(frame.height)) isPreview=\(isPreview)")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        animationTimeInterval = 1.0 / 60.0
    }

    // makeBackingLayer() is the canonical NSView override for customising the
    // backing layer type. AppKit calls it when the view is ready to back itself
    // — unlike setting `layer` directly in init, which races the layer setup.
    override func makeBackingLayer() -> CALayer {
        log.debug("makeBackingLayer → CAMetalLayer")
        return CAMetalLayer()
    }

    override func startAnimation() {
        super.startAnimation()
        log.info("startAnimation \(Int(self.bounds.width))×\(Int(self.bounds.height))")
        guard renderHandle == nil else { return }
        guard let metalLayer = layer as? CAMetalLayer else {
            log.error("layer is not CAMetalLayer — got \(String(describing: type(of: self.layer as AnyObject)))")
            return
        }
        let w = UInt32(max(bounds.width, 1))
        let h = UInt32(max(bounds.height, 1))
        renderHandle = starry_create(
            Unmanaged.passUnretained(metalLayer).toOpaque(), w, h
        )
        if renderHandle == nil {
            log.error("starry_create returned nil — GPU init failed")
        } else {
            log.info("starry_create OK")
        }
    }

    override func stopAnimation() {
        log.info("stopAnimation")
        if let h = renderHandle {
            starry_destroy(h)
            renderHandle = nil
        }
        super.stopAnimation()
    }

    override func animateOneFrame() {
        guard let h = renderHandle else { return }
        starry_frame(h)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let h = renderHandle else { return }
        log.debug("setFrameSize \(Int(newSize.width))×\(Int(newSize.height))")
        starry_resize(h, UInt32(max(newSize.width, 1)), UInt32(max(newSize.height, 1)))
    }

    // MARK: - Options panel

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? { configPanel }

    @objc private func closeConfigPanel(_ sender: Any?) {
        configPanel.sheetParent?.endSheet(configPanel)
    }

    private func makeConfigPanel() -> NSWindow {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Starry Night (Rust)"

        let label = NSTextField(wrappingLabelWithString:
            "Settings are read from the Swift screensaver preferences.\n" +
            "A dedicated preferences UI is planned for a future release."
        )
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "OK", target: self, action: #selector(closeConfigPanel))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.keyEquivalent = "\r"

        let cv = panel.contentView!
        cv.addSubview(label)
        cv.addSubview(button)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            button.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
        return panel
    }
}
