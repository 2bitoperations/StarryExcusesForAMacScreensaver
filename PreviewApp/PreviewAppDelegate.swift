//
//  PreviewAppDelegate.swift
//  StarryPreview
//
//  Creates a window hosting the screensaver view with the user's saved settings.
//

import AppKit
import ScreenSaver

class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var screensaverView: StarryExcuseForAView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the main screen size for a near-fullscreen experience, or a
        // reasonable fallback when running headless.
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Starry Preview"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black

        // isPreview: false — so the view uses full-quality rendering (not the
        // small System Preferences thumbnail mode). This also means the view
        // will NOT call NSApplication.terminate on screensaver-stop notifications
        // because that guard checks `isPreview`.
        //
        // Note: ScreenSaverView's `isPreview` flag is about the *System
        // Preferences* preview thumbnail — confusingly named. We pass false here
        // because we want full-size rendering. The willStopHandler in
        // StarryExcuseForAView only terminates when isPreview is false (i.e. when
        // running as an actual screensaver), so we override that behavior below
        // by NOT registering for those distributed notifications — but
        // StarryExcuseForAView registers them itself in requiredInternalInit().
        // We handle this by simply allowing terminate — the preview app *should*
        // quit when the screensaver stop notification fires, just like the real
        // screensaver does. This is fine for a dev tool.
        let view = StarryExcuseForAView(frame: screenFrame, isPreview: false)
        guard let saverView = view else {
            NSLog("StarryPreview: Failed to create StarryExcuseForAView")
            NSApplication.shared.terminate(nil)
            return
        }

        screensaverView = saverView
        saverView.showBuildOverlay = true

        // Use the screensaver's defaults domain so the preview app picks up
        // whatever the user configured in System Preferences / System Settings.
        saverView.useDefaultsModule("com.2bitoperations.screensaver.StarryExcuseForAMacScreensaver")

        window.contentView = saverView
        window.makeKeyAndOrderFront(nil)

        // ScreenSaverView manages its own animation timer once started.
        saverView.startAnimation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        screensaverView?.stopAnimation()
    }
}
