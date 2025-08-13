import Foundation
import CoreGraphics
import os

// Represents the moon, its phase (at Austin, TX local midnight of current day),
// and traversal parameters for a 1-hour arc animation across the screen.
//
// NOTE: Rendering no longer relies on overlapping circle area math;
// the renderer now uses a vertical chord approximation to create a
// visually familiar phase silhouette. We keep the illuminatedFraction
// and waxing state only.
struct Moon {
    // Static / configuration-ish (will make configurable later)
    static let synodicMonthDays: Double = 29.530588853
    static let newMoonEpoch: Date = {
        // Known New Moon: 2000-01-06 18:14:00 UTC (approx) often used as epoch.
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 6
        comps.hour = 18
        comps.minute = 14
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()
    
    // Traversal parameters
    let movingLeftToRight: Bool
    let radius: Int
    let arcAmplitude: Double
    let arcBaseY: Double
    let hourCycleSeconds: Double = 3600.0
    let screenWidth: Int
    let screenHeight: Int
    
    // Phase
    let illuminatedFraction: Double   // 0.0 new ... 1.0 full
    let waxing: Bool
    
    init(screenWidth: Int,
         screenHeight: Int,
         buildingMaxHeight: Int,
         log: OSLog,
         minRadius: Int = 15,
         maxRadius: Int = 60) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        
        // Random orientation & radius
        self.movingLeftToRight = Bool.random()
        let maxRLimitFromScreen = Int(0.12 * Double(min(screenWidth, screenHeight)))
        let allowedMaxR = min(maxRadius, maxRLimitFromScreen)
        let minR = minRadius
        let chosenRadiusRangeUpper = max(minR, allowedMaxR)
        self.radius = Int.random(in: minR...chosenRadiusRangeUpper)
        
        // Arc base Y (above buildings)
        let minBaseUnclamped = buildingMaxHeight + self.radius + 10
        let minBase = max(minBaseUnclamped, self.radius + 10)
        let maxBaseCandidate = minBase + Int(0.10 * Double(screenHeight))
        let maxBaseAllowed = screenHeight - self.radius - 10
        let baseUpper = min(maxBaseCandidate, maxBaseAllowed)
        let chosenBase = (baseUpper >= minBase) ? Int.random(in: minBase...baseUpper) : minBase
        self.arcBaseY = Double(chosenBase)
        
        // Arc amplitude (limit so apex stays on screen)
        let verticalHeadroom = Double(screenHeight - self.radius) - self.arcBaseY - 10.0
        let suggested = 0.15 * Double(screenHeight)
        let minAmplitude = 20.0
        let amplitudePreClamp = max(minAmplitude, suggested)
        self.arcAmplitude = min(amplitudePreClamp, max(0.0, verticalHeadroom))
        
        // Phase at Austin local midnight
        let phaseDate = Moon.midnightInAustin()
        let phaseResult = Moon.computePhase(on: phaseDate)
        let fraction = phaseResult.0
        let waxingFlag = phaseResult.1
        self.illuminatedFraction = fraction
        self.waxing = waxingFlag
        
        // Logging (kept simple)
        os_log("Moon init r=%{public}d frac=%.3f waxing=%{public}@",
               log: log, type: .info,
               self.radius, self.illuminatedFraction, self.waxing ? "true" : "false")
        os_log("Moon dir=%{public}@", log: log, type: .info,
               self.movingLeftToRight ? "L->R" : "R->L")
    }
    
    // Compute current center position based on real local time mapped to a repeating hour cycle.
    func currentCenter(now: Date = Date()) -> CGPoint {
        let calendar = Calendar(identifier: .gregorian)
        let localTZ = TimeZone.current
        let comps = calendar.dateComponents(in: localTZ, from: now)
        let hourSeconds = Double((comps.hour ?? 0) * 3600)
        let minuteSeconds = Double((comps.minute ?? 0) * 60)
        let secondSeconds = Double(comps.second ?? 0)
        let totalSeconds = hourSeconds + minuteSeconds + secondSeconds
        let loopSeconds = totalSeconds.truncatingRemainder(dividingBy: hourCycleSeconds)
        let progress = loopSeconds / hourCycleSeconds  // 0 -> 1 over an hour
        
        let usableWidth = Double(screenWidth - 2 * radius)
        let baseX = Double(radius)
        let x: Double = movingLeftToRight
            ? (progress * usableWidth + baseX)
            : ((1.0 - progress) * usableWidth + baseX)
        
        let angle = Double.pi * progress
        let verticalOffset = arcAmplitude * sin(angle)
        let y = arcBaseY + verticalOffset
        return CGPoint(x: x, y: y)
    }
    
    // MARK: - Phase calculations
    
    private static func midnightInAustin(reference: Date = Date()) -> Date {
        let tz = TimeZone(identifier: "America/Chicago")! // Austin, TX
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: tz, from: reference)
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        comps.nanosecond = 0
        comps.timeZone = tz
        return cal.date(from: comps)!
    }
    
    private static func julianDay(from date: Date) -> Double {
        let timeInterval = date.timeIntervalSince1970
        let daysSince1970 = timeInterval / 86400.0
        return 2440587.5 + daysSince1970
    }
    
    private static func computePhase(on date: Date) -> (Double, Bool) {
        let jd = julianDay(from: date)
        let epochJD = julianDay(from: newMoonEpoch)
        let daysSinceEpoch = jd - epochJD
        let rawAge = daysSinceEpoch.truncatingRemainder(dividingBy: synodicMonthDays)
        let normalizedAge = rawAge < 0 ? rawAge + synodicMonthDays : rawAge
        
        // fraction = (1 - cos θ)/2 with θ progressing 0..π from new to full
        let cyclePortion = normalizedAge / synodicMonthDays
        let phaseAngle = 2.0 * Double.pi * cyclePortion
        let cosine = cos(phaseAngle)
        let rawFraction = 0.5 * (1.0 - cosine)
        
        let waxing = normalizedAge < (synodicMonthDays / 2.0)
        let fraction = min(max(rawFraction, 0.0), 1.0)
        return (fraction, waxing)
    }
}
