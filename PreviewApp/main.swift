//
//  main.swift
//  StarryPreview
//
//  Lightweight app that hosts the screensaver view for quick iteration.
//

import AppKit

if ScreenshotMode.isScreenshotMode() {
    ScreenshotMode.run()
    exit(0)
} else {
    let app = NSApplication.shared
    let delegate = PreviewAppDelegate()
    app.delegate = delegate
    app.run()
}
