import Foundation
import CoreGraphics
import os

// Represents the moon, its phase, and traversal across the screen.
// Improvements (Tier 3):
//  - High‑resolution traversal time using a monotonic startTime instead of discrete H/M/S.
//  - Illuminated fraction & waxing state are now computed dynamically each access (unless
//    a phase override is enabled) so the phase actually advances over time.
//  - Provides smooth continuous motion suitable for subpixel rendering.
//
// Phase behavior:
// - If phaseOverrideEnabled == true, the override slider value (0.0 -> 1.0) maps
//   to illuminated fraction via a triangular wave:
//      p in [0,0.5]  -> illum = 2p (waxing)
//      p in (0.5,1] -> illum = 2 - 2p (waning)
// - If not overridden, we compute the live phase for the current instant using a
//   synodic month period and a reference epoch.
struct Moon {
    static let synodicMonthDays: Double = 29.530588853
    
    // Reference new moon epoch (UTC) used to compute phase angle.
    static let newMoonEpoch: Date = {
        var comps = DateComponents()
        comps.year = 2000; comps.month = 1; comps.day = 6
        comps.hour = 18; comps.minute = 14
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()
    
    // CONFIG / INITIAL STATE
    let movingLeftToRight: Bool
    let radius: Int
    let arcAmplitude: Double
    let arcBaseY: Double
    let traversalSeconds: Double
    let screenWidth: Int
    let screenHeight: Int
    
    // Phase override settings (stored; applied dynamically each access)
    private let phaseOverrideEnabled: Bool
    private let phaseOverrideValueClamped: Double
    
    // Motion timing
    private let startTime: TimeInterval  // monotonic reference (TimeInterval since reference date)
    
    // Texture (static grayscale albedo map)
    let textureImage: CGImage?
    
    init(screenWidth: Int,
         screenHeight: Int,
         buildingMaxHeight: Int,
         log: OSLog,
         radius: Int,
         traversalSeconds: Double = 3600.0,
         phaseOverrideEnabled: Bool = false,
         phaseOverrideValue: Double = 0.0) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.traversalSeconds = traversalSeconds
        
        // Always move left -> right (legacy variable logic removed for determinism).
        self.movingLeftToRight = true
        
        self.radius = max(1, radius)
        
        // Base Y for the traversal arc (randomized within a constrained band once at init).
        let minBaseUnclamped = buildingMaxHeight + self.radius + 10
        let minBase = max(minBaseUnclamped, self.radius + 10)
        let maxBaseCandidate = minBase + Int(0.10 * Double(screenHeight))
        let maxBaseAllowed = screenHeight - self.radius - 10
        let baseUpper = min(maxBaseCandidate, maxBaseAllowed)
        let chosenBase = (baseUpper >= minBase) ? Int.random(in: minBase...baseUpper) : minBase
        self.arcBaseY = Double(chosenBase)
        
        // Arc amplitude — limited so moon stays clear of screen edges.
        let verticalHeadroom = Double(screenHeight - self.radius) - self.arcBaseY - 10.0
        let suggested = 0.15 * Double(screenHeight)
        let minAmp = 20.0
        self.arcAmplitude = min(max(minAmp, suggested), max(0.0, verticalHeadroom))
        
        self.phaseOverrideEnabled = phaseOverrideEnabled
        self.phaseOverrideValueClamped = min(max(phaseOverrideValue, 0.0), 1.0)
        
        // High-resolution motion start reference (use system uptime-like reference for smooth progression).
        self.startTime = CFAbsoluteTimeGetCurrent()
        
        // Create albedo once (will be mipmapped later by Metal path).
        self.textureImage = MoonTexture.createMoonTexture(diameter: self.radius * 2)
        
        let (initIllum, initWax) = currentIllumination(now: Date())
        os_log("Moon init r=%{public}d illum=%.3f waxing=%{public}@ trav=%.0fs override=%{public}@ val=%.3f",
               log: log,
               type: .info,
               self.radius,
               initIllum,
               initWax ? "true" : "false",
               self.traversalSeconds,
               phaseOverrideEnabled ? "true" : "false",
               phaseOverrideValueClamped)
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
    func currentCenter(now: Date = Date()) -> CGPoint {
        // Use high-resolution delta since start (seconds).
        let t = now.timeIntervalSinceReferenceDate
        let elapsed = t - startTime
        let loop = traversalSeconds > 0 ? elapsed.truncatingRemainder(dividingBy: traversalSeconds) : 0
        let progress = traversalSeconds > 0 ? loop / traversalSeconds : 0
        
        let usableWidth = Double(screenWidth - 2 * radius)
        let baseX = Double(radius)
        let x: Double = movingLeftToRight
            ? (progress * usableWidth + baseX)
            : ((1.0 - progress) * usableWidth + baseX)
        
        // Vertical sinusoidal arc (half sine over traversal).
        let y = arcBaseY + arcAmplitude * sin(Double.pi * progress)
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
        let fraction = 0.5 * (1.0 - cos(phaseAngle))       // 0=new, 1=full
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
