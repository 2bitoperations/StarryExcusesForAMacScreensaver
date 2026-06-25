import ScreenSaver
import QuartzCore

// C FFI declarations — resolved at load time from libstarry_saver.dylib
// which is embedded in Contents/Frameworks/ and located via the rpath
// @loader_path/../Frameworks baked in by build-saver.sh.

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

// @objc(StarrySaverView) pins the Objective-C runtime name to the bare
// class name so NSPrincipalClass = "StarrySaverView" in Info.plist works
// regardless of the Swift module name.
@objc(StarrySaverView)
class StarrySaverView: ScreenSaverView {
    private var renderHandle: UnsafeMutableRawPointer?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        let metalLayer = CAMetalLayer()
        metalLayer.frame = bounds
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = metalLayer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func startAnimation() {
        super.startAnimation()
        animationTimeInterval = 1.0 / 60.0
        guard renderHandle == nil,
              let metalLayer = layer as? CAMetalLayer else { return }
        let w = UInt32(max(bounds.width, 1))
        let h = UInt32(max(bounds.height, 1))
        renderHandle = starry_create(
            Unmanaged.passUnretained(metalLayer).toOpaque(), w, h
        )
    }

    override func stopAnimation() {
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
        starry_resize(h, UInt32(max(newSize.width, 1)), UInt32(max(newSize.height, 1)))
    }
}
