import Cocoa

// Passive container for the live preview (replaces old bespoke moon rendering).
// The actual rendering is now done by StarryEngine via an NSImageView overlay
// inserted by StarryConfigSheetController. We intentionally disable custom drawing
// so the old divergent preview path no longer applies.
class MoonPreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Do nothing; StarryEngine handles drawing into the image view.
        // We keep this subclass so existing nib connections remain valid.
    }
}
