import Foundation
import CoreGraphics
import os

// Represents the moon, its phase (at Austin, TX local midnight of current day),
// and traversal parameters for a 1-hour arc animation across the screen.
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
    let shadowCenterOffset: Double    // distance between centers of illuminated base disc and dark (shadow) disc
    // (0 == fully dark, 2r == fully illuminated)
    
    // Faint outline threshold
    static let newMoonThreshold: Double = 0.02
    static let fullMoonThreshold: Double = 0.98
    
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
        let maxRDerived = Int(0.12 * Double(min(screenWidth, screenHeight)))
        let maxR = min(maxRadius, maxRDerived)
        let minR = minRadius
        self.radius = Int.random(in: minR...max(minR, maxR))
        
        // Arc amplitude & base placement (ensure stays fully on screen)
        // Base Y just above buildings (buildingMaxHeight) plus a small random extra.
        let minBase = max(buildingMaxHeight + self.radius + 10, self.radius + 10)
        let maxBaseCandidate = minBase + Int(0.10 * Double(screenHeight))
        let maxBaseLimit = screenHeight - self.radius - 10
        let actualMaxBase = min(maxBaseCandidate, maxBaseLimit)
        self.arcBaseY = Double(Int.random(in: minBase...actualMaxBase))
        
        // Amplitude chosen so that apex stays within screen.
        let maxPossibleAmplitude = Double(screenHeight - self.radius) - self.arcBaseY - 10.0
        let suggestedAmplitudeRange = max(20.0, 0.15 * Double(screenHeight))
        let amplitude = min(max(20.0, suggestedAmplitudeRange), maxPossibleAmplitude)
        self.arcAmplitude = amplitude
        
        // Phase at Austin local midnight
        let phaseDate = Moon.midnightInAustin()
        let (fraction, waxingFlag) = Moon.computePhase(on: phaseDate)
        self.illuminatedFraction = fraction
        self.waxing = waxingFlag
        
        // Precompute shadow center distance for overlap model so that
        // Illuminated fraction ≈ desired fraction using:
        // Illuminated = 1 - overlapArea/(π r²)
        if fraction <= Moon.newMoonThreshold {
            self.shadowCenterOffset = 0.0
        } else if fraction >= Moon.fullMoonThreshold {
            self.shadowCenterOffset = Double(2 * self.radius)
        } else {
            self.shadowCenterOffset = Moon.solveShadowOffset(forFraction: fraction, radius: Double(self.radius))
        }
        
        // Split logging into simpler statements to help compiler type-check quickly
        os_log("Moon initialized r=%{public}d fraction=%.3f waxing=%{public}@", log: log, type: .info,
               self.radius, self.illuminatedFraction, String(self.waxing))
        os_log("Moon offset=%.2f direction=%{public}@", log: log, type: .info,
               self.shadowCenterOffset, self.movingLeftToRight ? "L->R" : "R->L")
    }
    
    // Compute current center position based on real local time mapped to a repeating hour cycle.
    func currentCenter(now: Date = Date()) -> CGPoint {
        let calendar = Calendar(identifier: .gregorian)
        let localTZ = TimeZone.current // Use system local time (user machine); arc progress loops hourly
        let comps = calendar.dateComponents(in: localTZ, from: now)
        let seconds = Double((comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0))
        let progress = (seconds.truncatingRemainder(dividingBy: hourCycleSeconds)) / hourCycleSeconds // 0 -> 1 over hour
        let horizontalSpan = Double(screenWidth - 2 * radius)
        let x: Double
        if movingLeftToRight {
            x = progress * horizontalSpan + Double(radius)
        } else {
            x = (1.0 - progress) * horizontalSpan + Double(radius)
        }
        let y = arcBaseY + arcAmplitude * sin(Double.pi * progress)
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
        // Convert date to Julian Day (UTC)
        let timeInterval = date.timeIntervalSince1970 // seconds since 1970 UTC
        let daysSince1970 = timeInterval / 86400.0
        // JD for Unix epoch 1970-01-01 00:00:00 UTC = 2440587.5
        return 2440587.5 + daysSince1970
    }
    
    private static func computePhase(on date: Date) -> (Double, Bool) {
        // Based on the difference in days from known new moon epoch
        let jd = julianDay(from: date)
        let epochJD = julianDay(from: newMoonEpoch)
        let daysSinceEpoch = jd - epochJD
        let ageRaw = daysSinceEpoch.truncatingRemainder(dividingBy: synodicMonthDays)
        let normalizedAge = ageRaw < 0 ? ageRaw + synodicMonthDays : ageRaw
        
        // Break complex expression into smaller parts
        let cyclePortion = normalizedAge / synodicMonthDays
        let phaseAngle = 2.0 * Double.pi * cyclePortion
        let cosPhase = cos(phaseAngle)
        let fraction = 0.5 * (1.0 - cosPhase)
        
        let waxing = normalizedAge < (synodicMonthDays / 2.0)
        let clamped = min(max(fraction, 0.0), 1.0)
        return (clamped, waxing)
    }
    
    // Solve distance d between centers (0...2r) so that overlap area gives illuminated fraction f
    // Illuminated fraction f = 1 - overlap/(π r²)
    // Binary search for d.
    private static func solveShadowOffset(forFraction f: Double, radius r: Double) -> Double {
        let targetOverlap = (1.0 - f) * Double.pi * r * r
        var low = 0.0
        var high = 2.0 * r
        for _ in 0..<40 {
            let mid = 0.5 * (low + high)
            let overlap = circleOverlapArea(r: r, d: mid)
            if overlap > targetOverlap {
                low = mid
            } else {
                high = mid
            }
        }
        return 0.5 * (low + high)
    }
    
    // Area of overlap between two circles of equal radius r separated by distance d (0 <= d <= 2r)
    private static func circleOverlapArea(r: Double, d: Double) -> Double {
        if d <= 0 { return Double.pi * r * r }
        if d >= 2 * r { return 0.0 }
        let term = d / (2.0 * r)
        let acosTerm = acos(term)
        let part1 = 2.0 * r * r * acosTerm
        let sqrtTerm = sqrt(max(0.0, 4.0 * r * r - d * d))
        let part2 = 0.5 * d * sqrtTerm
        return part1 - part2
    }
}
