import AppKit
import Foundation
import Darwin

enum ScreenshotMode {
    private static let saverModuleIdentifier = "com.2bitoperations.screensaver.StarryExcuseForAMacScreensaver"
    private static let defaultFrames = 100
    private static let defaultWidth = 1920
    private static let defaultHeight = 1080

    static func isScreenshotMode() -> Bool {
        CommandLine.arguments.contains("--screenshot")
    }

    static func run() {
        do {
            let args = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            guard let outputPath = args["--screenshot"], !outputPath.isEmpty else {
                throw ScreenshotError.invalidArgument("--screenshot requires a path")
            }

            let frames = try parseIntArg(args, key: "--frames", defaultValue: defaultFrames)
            let width = try parseIntArg(args, key: "--width", defaultValue: defaultWidth)
            let height = try parseIntArg(args, key: "--height", defaultValue: defaultHeight)

            guard frames > 0 else {
                throw ScreenshotError.invalidArgument("--frames must be > 0")
            }
            guard width > 0 else {
                throw ScreenshotError.invalidArgument("--width must be > 0")
            }
            guard height > 0 else {
                throw ScreenshotError.invalidArgument("--height must be > 0")
            }

            let defaults = StarryDefaultsManager(moduleIdentifier: saverModuleIdentifier)
            defaults.defaults.removePersistentDomain(forName: saverModuleIdentifier)
            defaults.defaults.synchronize()
            try applyConfigOverrides(args: args, defaults: defaults)

            if args["--planet-position-mode"] == nil {
                defaults.planetBelowHorizonBehavior = "random"
            }
            if args["--debug-overlay"] == nil {
                defaults.debugOverlayEnabled = false
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let frameRect = NSRect(x: 100, y: 100, width: width, height: height)
            let window = NSWindow(
                contentRect: frameRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false

            guard let saverView = StarryExcuseForAView(frame: frameRect, isPreview: false) else {
                throw ScreenshotError.runtime("Failed to create StarryExcuseForAView")
            }

            saverView.useDefaultsModule(saverModuleIdentifier)
            window.contentView = saverView
            window.makeKeyAndOrderFront(nil)
            saverView.startAnimation()

            let interval = max(0.05, Double(frames) * saverView.animationTimeInterval)
            Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                do {
                    try capturePng(from: window, outputPath: outputPath)
                    saverView.stopAnimation()
                    exit(0)
                } catch {
                    fputs("StarryPreview screenshot error: \(error)\n", stderr)
                    saverView.stopAnimation()
                    exit(1)
                }
            }

            RunLoop.main.run()
        } catch {
            fputs("StarryPreview screenshot error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseArguments(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let key = args[index]
            guard key.hasPrefix("--") else {
                throw ScreenshotError.invalidArgument("Invalid key: \(key)")
            }

            if key == "--debug-moon-colors" {
                result[key] = "true"
                index += 1
                continue
            }

            guard index + 1 < args.count else {
                throw ScreenshotError.invalidArgument("\(key) requires a value")
            }

            let value = args[index + 1]
            result[key] = value
            index += 2
        }
        return result
    }

    private static func parseIntArg(
        _ args: [String: String],
        key: String,
        defaultValue: Int
    ) throws -> Int {
        guard let raw = args[key] else { return defaultValue }
        guard let value = Int(raw) else {
            throw ScreenshotError.invalidArgument("\(key) expects integer, got '\(raw)'")
        }
        return value
    }

    private static func parseDoubleArg(_ args: [String: String], key: String) throws -> Double? {
        guard let raw = args[key] else { return nil }
        guard let value = Double(raw), value.isFinite else {
            throw ScreenshotError.invalidArgument("\(key) expects number, got '\(raw)'")
        }
        return value
    }

    private static func parseBoolArg(_ args: [String: String], key: String) throws -> Bool? {
        guard let raw = args[key]?.lowercased() else { return nil }
        switch raw {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            throw ScreenshotError.invalidArgument("\(key) expects bool (true/false), got '\(raw)'")
        }
    }

    private static func applyConfigOverrides(args: [String: String], defaults: StarryDefaultsManager) throws {
        func setDouble(_ key: String, _ assign: (Double) -> Void) throws {
            if let value = try parseDoubleArg(args, key: key) {
                assign(value)
            }
        }

        func setInt(_ key: String, _ assign: (Int) -> Void) throws {
            guard let raw = args[key] else { return }
            guard let value = Int(raw) else {
                throw ScreenshotError.invalidArgument("\(key) expects integer, got '\(raw)'")
            }
            assign(value)
        }

        func setBool(_ key: String, _ assign: (Bool) -> Void) throws {
            if let value = try parseBoolArg(args, key: key) {
                assign(value)
            }
        }

        func setString(_ key: String, _ assign: (String) -> Void) {
            if let value = args[key], !value.isEmpty {
                assign(value)
            }
        }

        try setDouble("--star-density") { defaults.starSpawnFractionOfMax = $0 }
        try setDouble("--building-lights-density") { defaults.buildingLightsSpawnFractionOfMax = $0 }
        try setDouble("--building-height") { defaults.buildingHeight = $0 }
        try setDouble("--building-frequency") { defaults.buildingFrequency = $0 }
        try setDouble("--secs-between-clears") { defaults.secsBetweenClears = $0 }
        try setInt("--moon-traversal-minutes") { defaults.moonTraversalMinutes = $0 }
        try setDouble("--moon-diameter") { defaults.moonDiameterScreenWidthPercent = $0 }
        try setDouble("--moon-bright") { defaults.moonBrightBrightness = $0 }
        try setDouble("--moon-dark") { defaults.moonDarkBrightness = $0 }
        try setDouble("--moon-phase-override") {
            defaults.moonPhaseOverrideEnabled = true
            defaults.moonPhaseOverrideValue = $0
        }
        try setInt("--moon-terminator-mode") { defaults.moonTerminatorMode = $0 }
        try setDouble("--moon-terminator-width") { defaults.moonTerminatorWidth = $0 }
        try setInt("--moon-terminator-bands") { defaults.moonTerminatorBands = $0 }
        try setBool("--shooting-stars") { defaults.shootingStarsEnabled = $0 }
        try setDouble("--shooting-stars-avg-seconds") { defaults.shootingStarsAvgSeconds = $0 }
        try setInt("--shooting-stars-direction-mode") { defaults.shootingStarsDirectionMode = $0 }
        try setDouble("--shooting-stars-length") { defaults.shootingStarsLength = $0 }
        try setDouble("--shooting-stars-speed") { defaults.shootingStarsSpeed = $0 }
        try setDouble("--shooting-stars-thickness") { defaults.shootingStarsThickness = $0 }
        try setDouble("--shooting-stars-brightness") { defaults.shootingStarsBrightness = $0 }
        try setBool("--satellites") { defaults.satellitesEnabled = $0 }
        try setDouble("--satellites-avg-spawn") { defaults.satellitesAvgSpawnSeconds = $0 }
        try setDouble("--satellites-speed") { defaults.satellitesSpeed = $0 }
        try setDouble("--satellites-size") { defaults.satellitesSize = $0 }
        try setDouble("--satellites-brightness") { defaults.satellitesBrightness = $0 }
        try setBool("--satellites-trailing") { defaults.satellitesTrailing = $0 }
        try setInt("--star-sampling-mode") { defaults.starSamplingMode = $0 }
        try setDouble("--mercury-size") { defaults.mercurySize = $0 }
        try setDouble("--venus-size") { defaults.venusSize = $0 }
        try setDouble("--mars-size") { defaults.marsSize = $0 }
        try setDouble("--jupiter-size") { defaults.jupiterSize = $0 }
        try setDouble("--saturn-size") { defaults.saturnSize = $0 }
        try setDouble("--uranus-size") { defaults.uranusSize = $0 }
        try setDouble("--neptune-size") { defaults.neptuneSize = $0 }
        try setDouble("--pluto-size") { defaults.plutoSize = $0 }
        setString("--planet-position-mode") { defaults.planetBelowHorizonBehavior = $0 }
        setString("--planet-terminator-mode") { defaults.planetTerminatorMode = $0 }
        setString("--saturn-ring-tilt-mode") { defaults.saturnRingTiltMode = $0 }
        try setDouble("--saturn-ring-tilt") {
            defaults.saturnRingTiltMode = "manual"
            defaults.saturnRingTiltAngle = $0
        }
        setString("--saturn-ring-rotation-mode") { defaults.saturnRingRotationMode = $0 }
        try setDouble("--saturn-ring-rotation") {
            defaults.saturnRingRotationMode = "manual"
            defaults.saturnRingRotationAngle = $0
        }
        try setInt("--saturn-ring-style") { defaults.saturnRingStyle = $0 }
        try setBool("--debug-overlay") { defaults.debugOverlayEnabled = $0 }
        if args["--debug-moon-colors"] != nil {
            defaults.debugMoonColors = true
        }
    }

    // CGWindowListCreateImage is deprecated in favour of ScreenCaptureKit, but
    // SCK requires async + TCC permissions — too heavy for test infrastructure.
    @_silgen_name("CGWindowListCreateImage")
    private static func windowListCreateImage(
        _ screenBounds: CGRect,
        _ listOption: CGWindowListOption,
        _ windowID: CGWindowID,
        _ imageOption: CGWindowImageOption
    ) -> CGImage?

    private static func capturePng(from window: NSWindow, outputPath: String) throws {
        guard let cgImage = windowListCreateImage(
            window.frame,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            .bestResolution
        ) else {
            throw ScreenshotError.runtime("Failed to capture window")
        }
        
        let rep = NSBitmapImageRep(cgImage: cgImage)
        
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.runtime("Unable to encode PNG data")
        }
        
        let outputURL = URL(fileURLWithPath: outputPath)
        let parentURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try pngData.write(to: outputURL)
    }
}

private enum ScreenshotError: LocalizedError {
    case invalidArgument(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message): return message
        case let .runtime(message): return message
        }
    }
}
