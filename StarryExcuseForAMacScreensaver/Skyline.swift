//
//  Skyline.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 2019-04-29
//

import CoreGraphics
import Foundation
import os

enum StateError: Error {
    case ConstraintViolation(msg: String)
}

class Skyline {
    let buildings: [Building]
    let width: Int
    let height: Int
    let buildingLightsPerUpdate: Int
    let buildingMaxHeight: Int
    let buildingColor: Color
    let log: OSLog
    let flasherRadius: Int
    let flasherPeriod: TimeInterval
    var flasherPosition: Point?
    var flasherOnAt: NSDate
    let createdAt: NSDate
    let clearAfterDuration: TimeInterval
    let traceEnabled: Bool

    private let moon: Moon?
    let moonBrightBrightness: Double
    let moonDarkBrightness: Double
    let moonPhaseOverrideEnabled: Bool
    let moonPhaseOverrideValue: Double
    // Moon diameter as a percentage of the screen width (0.0 - 1.0 clamped to sane range)
    let moonDiameterScreenWidthPercent: Double
    // Computed fixed moon radius
    let moonRadius: Int

    init(
        screenXMax: Int,
        screenYMax: Int,
        buildingHeightPercentMax: Double = 0.35,
        buildingWidthMin: Int = 40,
        buildingWidthMax: Int = 300,
        buildingFrequency: Double = 0.033,  // ~100 buildings on a 3000px wide screen
        buildingLightsPerUpdate: Int = 15,
        buildingColor: Color = Color(red: 0.972, green: 0.945, blue: 0.012),
        flasherRadius: Int = 4,
        flasherPeriod: TimeInterval = 2.0,
        log: OSLog,
        clearAfterDuration: TimeInterval = 120,
        traceEnabled: Bool = false,
        moonTraversalSeconds: Double = 3600.0,
        moonBrightBrightness: Double = 1.0,
        moonDarkBrightness: Double = 0.15,
        // Default chosen so on a 3000px wide screen you get ~80px diameter (80/3000 ≈ 0.0266667).
        moonDiameterScreenWidthPercent: Double = (80.0 / 3000.0),
        moonPhaseOverrideEnabled: Bool = false,
        moonPhaseOverrideValue: Double = 0.0
    ) throws {
        self.log = log
        var buildingWorkingList = [Building]()
        self.width = screenXMax
        self.height = screenYMax
        self.buildingLightsPerUpdate = buildingLightsPerUpdate
        let styles = BuildingStyle.getBuildingStyles()
        self.buildingMaxHeight = Int(
            Double(screenYMax) * buildingHeightPercentMax
        )
        self.buildingColor = buildingColor
        self.flasherRadius = flasherRadius
        self.flasherPeriod = flasherPeriod
        self.flasherOnAt = NSDate()
        self.createdAt = NSDate()
        self.clearAfterDuration = clearAfterDuration
        self.traceEnabled = traceEnabled
        self.moonBrightBrightness = moonBrightBrightness
        self.moonDarkBrightness = moonDarkBrightness
        self.moonDiameterScreenWidthPercent = moonDiameterScreenWidthPercent
        self.moonPhaseOverrideEnabled = moonPhaseOverrideEnabled
        self.moonPhaseOverrideValue = min(max(moonPhaseOverrideValue, 0.0), 1.0)

        // Compute moon radius from percentage of screen width.
        let clampedPercent = max(
            0.001,
            min(0.25, self.moonDiameterScreenWidthPercent)
        )  // clamp to sane bounds
        let moonDiameter = Double(screenXMax) * clampedPercent
        self.moonRadius = max(1, Int(round(moonDiameter / 2.0)))

        os_log(
            "invoking skyline init, screen %{PUBLIC}dx%{PUBLIC}d",
            log: log,
            type: .info,
            screenXMax,
            screenYMax
        )
        os_log("found %{PUBLIC}d styles", log: log, type: .debug, styles.count)
        os_log(
            "moon size percent=%{PUBLIC}.5f diameter≈%{PUBLIC}.1fpx radius=%{PUBLIC}d",
            log: log,
            type: .info,
            clampedPercent,
            moonDiameter,
            moonRadius
        )

        // Compute building count from frequency and screen width.
        let computedBuildingCount = max(
            0,
            Int(Double(screenXMax) * buildingFrequency)
        )

        for buildingZIndex in 0...computedBuildingCount {
            let style = styles[Int.random(in: 0...styles.count - 1)]
            let height = Skyline.getWeightedRandomHeight(
                maxHeight: buildingMaxHeight
            )
            let buildingXStart = Int.random(in: 0...screenXMax - 1)
            let buildingWidth = min(
                Int.random(in: buildingWidthMin...buildingWidthMax - 1),
                screenXMax - buildingXStart
            )
            let building = try Building(
                width: buildingWidth,
                height: height,
                startX: buildingXStart,
                startY: 0,
                zCoordinate: buildingZIndex,
                style: style
            )
            buildingWorkingList.append(building)
        }

        buildings = buildingWorkingList.sorted { a, b in a.startX < b.startX }

        for b in buildings {
            os_log(
                "created building at %{public}d, width %{public}d, height %{public}d",
                log: log,
                type: .info,
                b.startX,
                b.width,
                b.height
            )
        }

        self.moon = Moon(
            screenWidth: screenXMax,
            screenHeight: screenYMax,
            buildingMaxHeight: self.buildingMaxHeight,
            log: log,
            radius: self.moonRadius,
            traversalSeconds: moonTraversalSeconds,
            phaseOverrideEnabled: moonPhaseOverrideEnabled,
            phaseOverrideValue: self.moonPhaseOverrideValue
        )

        self.flasherPosition = getFlasherPosition()
    }

    static func getWeightedRandomHeight(maxHeight: Int) -> Int {
        let weighted = pow(Double.random(in: 0.01...1), 2)
        return max(1, Int(weighted * Double(maxHeight)))
    }

    func shouldClearNow() -> Bool {
        return abs(self.createdAt.timeIntervalSinceNow)
            > self.clearAfterDuration
    }

    func getSingleStar() -> Point {
        var y: Int
        var x: Int
        repeat {
            y = Skyline.getWeightedRandomHeight(maxHeight: self.height)
            x = Int.random(in: 0...self.width)
        } while getBuildingAtPoint(screenXPos: x, screenYPos: y) != nil
        let color = Color(
            red: Double.random(in: 0.0...0.5),
            green: Double.random(in: 0.0...0.5),
            blue: Double.random(in: 0.0...1)
        )
        return Point(xPos: x, yPos: y, color: color)
    }

    func getSingleBuildingPoint() -> Point {
        var y = 0
        var x = 0
        var buildingAtPos: Building?
        var lightOn = false
        while buildingAtPos == nil || !lightOn {
            x = Int.random(in: 0...self.width - 1)
            y = Int.random(in: 0...self.height - 1)
            buildingAtPos = getBuildingAtPoint(screenXPos: x, screenYPos: y)
            if let b = buildingAtPos {
                lightOn = b.isLightOn(screenXPos: x, screenYPos: y)
            }
        }
        return Point(xPos: x, yPos: y, color: buildingColor)
    }

    func getBuildingAtPoint(screenXPos: Int, screenYPos: Int) -> Building? {
        var front: Building?
        for b in buildings {
            if b.startX > screenXPos { break }
            if b.isPixelInsideBuilding(
                screenXPos: screenXPos,
                screenYPos: screenYPos
            ) {
                if let f = front {
                    if b.zCoordinate > f.zCoordinate { front = b }
                } else {
                    front = b
                }
            }
        }
        return front
    }

    func getTallestBuilding() -> Building? {
        buildings.max { $0.height < $1.height }
    }

    private func getFlasherPosition() -> Point? {
        guard let building = getTallestBuilding() else { return nil }
        let fx = building.startX + (building.width / 2)
        let fy = building.startY + building.height + flasherRadius
        return Point(
            xPos: fx,
            yPos: fy,
            color: Color(red: 1.0, green: 0.0, blue: 0.0)
        )
    }

    func getFlasher() -> Point? {
        guard let flasherPosition = flasherPosition else { return nil }
        if flasherPeriod <= 0 { return nil }
        if abs(flasherOnAt.timeIntervalSinceNow) < flasherPeriod / 2 {
            return flasherPosition
        } else if abs(flasherOnAt.timeIntervalSinceNow) < flasherPeriod {
            return Point(
                xPos: flasherPosition.xPos,
                yPos: flasherPosition.yPos,
                color: Color(red: 0, green: 0, blue: 0)
            )
        } else {
            flasherOnAt = NSDate()
            return flasherPosition
        }
    }

    /// Returns static flasher geometry if available.
    /// centerX / centerY represent the center of the flasher (not the top).
    /// radius matches the configured flasherRadius used during initialization.
    /// Returns nil if no flasher was created (e.g., no buildings).
    func getFlasherDetails() -> (centerX: Int, centerY: Int, radius: Int)? {
        guard let p = flasherPosition else { return nil }
        return (p.xPos, p.yPos, flasherRadius)
    }

    func getMoon() -> Moon? { moon }
}
