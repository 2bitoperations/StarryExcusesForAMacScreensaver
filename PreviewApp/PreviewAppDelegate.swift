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

    private static let saverModuleIdentifier =
        "com.2bitoperations.screensaver.StarryExcuseForAMacScreensaver"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        seedDefaultsFromScreenSaverContainer()

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
        saverView.useDefaultsModule(Self.saverModuleIdentifier)

        window.contentView = saverView
        window.makeKeyAndOrderFront(nil)

        // ScreenSaverView manages its own animation timer once started.
        saverView.startAnimation()
    }

    // MARK: - Sandboxed-container defaults bridge
    //
    // On modern macOS, screensavers run inside the sandboxed container
    // com.apple.ScreenSaver.Engine.legacyScreenSaver. ScreenSaverDefaults
    // persists preferences into that container's ByHost directory:
    //
    //   ~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/
    //     Data/Library/Preferences/ByHost/<module-id>.<hardware-uuid>.plist
    //
    // A standalone app can't see those values through ScreenSaverDefaults
    // because it resolves to a different (non-containerized) location.
    //
    // This method reads the container plist directly and seeds the values
    // into the ScreenSaverDefaults instance the preview app will use.
    // If the plist isn't found (e.g. screensaver was never configured),
    // StarryDefaultsManager's built-in fallback defaults take over.
    //
    // If this breaks after a macOS update, check whether Apple changed the
    // container name or the ByHost storage path. See AGENTS.md for more
    // context on this quirk.

    private func seedDefaultsFromScreenSaverContainer() {
        let containerPath = NSHomeDirectory()
            + "/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver"
            + "/Data/Library/Preferences/ByHost"

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: containerPath)
        else {
            NSLog("StarryPreview: container ByHost dir not found — using default settings")
            return
        }

        let prefix = Self.saverModuleIdentifier + "."
        guard let plistName = contents.first(where: {
            $0.hasPrefix(prefix) && $0.hasSuffix(".plist")
        }) else {
            NSLog("StarryPreview: no matching plist in container — using default settings")
            return
        }

        let plistPath = containerPath + "/" + plistName
        guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
            NSLog("StarryPreview: failed to read plist at %@", plistPath)
            return
        }

        guard let target = ScreenSaverDefaults(forModuleWithName: Self.saverModuleIdentifier)
        else {
            NSLog("StarryPreview: failed to create ScreenSaverDefaults for seeding")
            return
        }

        for (key, value) in dict {
            target.set(value, forKey: key)
        }
        target.synchronize()

        NSLog("StarryPreview: seeded %d settings from container plist", dict.count)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        screensaverView?.stopAnimation()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit StarryPreview",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        NSApplication.shared.mainMenu = mainMenu
    }
}
