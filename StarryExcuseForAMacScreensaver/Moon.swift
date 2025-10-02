import CoreGraphics
import Foundation
import os

// Represents the moon, its phase, and traversal across the screen.
//
// Traversal behavior (reintroduced feature):
//  - The moon traverses left -> right along a single arch once per configured
//    traversal duration (traversalSeconds).
//  - Position is tied to wall‐clock time, not the object’s creation time:
//        progress = (wallClockSeconds % traversalSeconds) / traversalSeconds
//    This guarantees deterministic synchronization if multiple Moons were
//    created simultaneously and allows “popping” back to the left edge exactly
//    at the moment the modulo resets.
//  - Horizontal motion is linear across the usable width.
//  - Vertical motion is a smooth single arch using a half‑sine curve:
//        y = verticalBaseY + verticalArchHeight * sin(pi * progress)
//    Which yields: y(left) = verticalBaseY, y(mid) = verticalBaseY + verticalArchHeight,
//                  y(right) = verticalBaseY
//
//  verticalBaseY and verticalArchHeight are randomized once at initialization
//  (constrained so the moon remains fully visible and above buildings).
//
// Phase behavior:
//  - If phaseOverrideEnabled == true, the override slider value (0.0 -> 1.0) maps
//    to illuminated fraction via a triangular wave:
//       p in [0,0.5]  -> illum = 2p   (waxing)
//       p in (0.5,1]  -> illum = 2 - 2p (waning)
//  - Otherwise we compute live phase based on a reference new‑moon epoch
//    using the synodic month length. This is evaluated each access so the
//    phase naturally advances over time without explicit ticking.
struct Moon {
    // Astronomical constants
    static let synodicMonthDays: Double = 29.530588853

    // Reference new moon epoch (UTC) used to compute phase angle.
    static let newMoonEpoch: Date = {
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 6
        comps.hour = 18
        comps.minute = 14
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()

    // CONFIG / INITIAL STATE
    let movingLeftToRight: Bool
    let radius: Int

    // Vertical arch parameters (randomized once)
    // verticalBaseY: baseline Y value at left/right ends of traversal
    // verticalArchHeight: additional height reached at traversal midpoint (peak)
    let verticalBaseY: Double
    let verticalArchHeight: Double

    // Total seconds for one full left->right traversal (honors config)
    let traversalSeconds: Double

    let screenWidth: Int
    let screenHeight: Int

    // Phase override settings (stored; applied dynamically each access)
    private let phaseOverrideEnabled: Bool
    private let phaseOverrideValueClamped: Double

    // Texture (static grayscale albedo map)
    let textureImage: CGImage?

    init(
        screenWidth: Int,
        screenHeight: Int,
        buildingMaxHeight: Int,
        log: OSLog,
        radius: Int,
        traversalSeconds: Double = 3600.0,
        phaseOverrideEnabled: Bool = false,
        phaseOverrideValue: Double = 0.0
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight

        // Honor traversalSeconds passed in (minimum safeguard to avoid div-by-zero)
        self.traversalSeconds = traversalSeconds > 1.0 ? traversalSeconds : 3600.0

        // Always move left -> right for deterministic simplicity (legacy random direction removed).
        self.movingLeftToRight = true

        self.radius = max(1, radius)

        // --- Vertical arch randomization ---
        //
        // We ensure the baseline stays above the tallest buildings + padding so the
        // moon does not clip, and also leaves room for the arch peak.
        //
        // verticalBaseY is chosen within a band:
        //   minimumBase = buildingMaxHeight + radius + 10
        //   maximumBaseCandidate = minimumBase + 10% of screen height
        //   Also must allow room for peak (verticalArchHeight) without exceeding screen.
        //
        // verticalArchHeight: chosen so the peak remains on-screen (radius margin).
        let minBaseUnclamped = buildingMaxHeight + self.radius + 10
        let minBase = max(minBaseUnclamped, self.radius + 10)
        let baseUpperCandidate = minBase + Int(0.10 * Double(screenHeight))
        let maxBaseAllowed = screenHeight - self.radius - 10
        let baseUpper = min(baseUpperCandidate, maxBaseAllowed)
        let chosenBase =
            (baseUpper >= minBase)
            ? Int.random(in: minBase...baseUpper) : minBase
        self.verticalBaseY = Double(chosenBase)

        // Determine maximum possible arch height given remaining headroom.
        let verticalHeadroom =
            Double(screenHeight - self.radius) - self.verticalBaseY - 10.0
        let suggested = 0.15 * Double(screenHeight)
        let minArch = 20.0
        self.verticalArchHeight = min(
            max(minArch, suggested),
            max(0.0, verticalHeadroom)
        )

        self.phaseOverrideEnabled = phaseOverrideEnabled
        self.phaseOverrideValueClamped = min(max(phaseOverrideValue, 0.0), 1.0)

        // Create albedo once (will be mipmapped later by Metal path).
        self.textureImage = MoonTexture.createMoonTexture(
            diameter: self.radius * 2
        )

        let (initIllum, initWax) = currentIllumination(now: Date())
        os_log(
            "Moon init r=%{public}d illum=%.3f waxing=%{public}@ traversal=%.0fs (wall-clock modulo) override=%{public}@ val=%.3f baseY=%.1f archH=%.1f",
            log: log,
            type: .info,
            self.radius,
            initIllum,
            initWax ? "true" : "false",
            self.traversalSeconds,
            phaseOverrideEnabled ? "true" : "false",
            phaseOverrideValueClamped,
            self.verticalBaseY,
            self.verticalArchHeight
        )
    }

    // Dynamic illuminated fraction (0=new, 1=full).
    var illuminatedFraction: Double {
        let (f, _) = currentIllumination(now: Date())
        return f
    }

    // Dynamic waxing flag
    var waxing: Bool {
        let (_, w) = currentIllumination(now: Date())
        return w
    }

    // Compute the moon position at the supplied Date (or now).
    // Traversal progress is derived from wall-clock time modulo traversalSeconds
    // so that multiple instances stay synchronized and the moon "pops" back to
    // the left when the cycle completes.
    func currentCenter(now: Date = Date()) -> CGPoint {
        let cycleDuration = traversalSeconds > 0 ? traversalSeconds : 3600.0
        let t = now.timeIntervalSince1970
        let cycleElapsed = t.truncatingRemainder(dividingBy: cycleDuration)
        let progress = cycleElapsed / cycleDuration  // 0 -> <1

        let usableWidth = Double(screenWidth - 2 * radius)
        let leftX = Double(radius)
        let x: Double =
            movingLeftToRight
            ? (progress * usableWidth + leftX)
            : ((1.0 - progress) * usableWidth + leftX)

        // Vertical half-sine arch
        let y = verticalBaseY + verticalArchHeight * sin(Double.pi * progress)

        return CGPoint(x: x, y: y)
    }

    // MARK: - Phase Computation

    private static func julianDay(from date: Date) -> Double {
        let timeInterval = date.timeIntervalSince1970
        return 2440587.5 + timeInterval / 86400.0
    }

    private static func computePhase(on date: Date) -> (Double, Bool) {
        let jd = julianDay(from: date)
        let epochJD = julianDay(from: newMoonEpoch)
        let days = jd - epochJD
        let ageRaw = days.truncatingRemainder(dividingBy: synodicMonthDays)
        let age = ageRaw < 0 ? ageRaw + synodicMonthDays : ageRaw
        let cyclePortion = age / synodicMonthDays
        let phaseAngle = 2.0 * Double.pi * cyclePortion
        let fraction = 0.5 * (1.0 - cos(phaseAngle))  // 0=new, 1=full
        let waxing = age < (synodicMonthDays / 2.0)
        return (min(max(fraction, 0.0), 1.0), waxing)
    }

    // Returns (illuminatedFraction, waxing)
    private func currentIllumination(now: Date) -> (Double, Bool) {
        if phaseOverrideEnabled {
            // Triangular mapping controlled by slider.
            let p = phaseOverrideValueClamped
            if p <= 0.5 {
                return (2.0 * p, true)
            } else {
                return (2.0 - 2.0 * p, false)
            }
        } else {
            return Moon.computePhase(on: now)
        }
    }
}
