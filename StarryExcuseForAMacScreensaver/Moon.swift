import Foundation
import CoreGraphics
import os

// Represents the moon, its phase, and traversal across the screen.
// Incorporates configurable traversal duration and radius range (from defaults).
struct Moon {
    static let synodicMonthDays: Double = 29.530588853
    static let referenceLatitude: Double = 30.2672 // Austin, TX
    
    static let newMoonEpoch: Date = {
        var comps = DateComponents()
        comps.year = 2000; comps.month = 1; comps.day = 6
        comps.hour = 18; comps.minute = 14
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()
    
    let movingLeftToRight: Bool
    let radius: Int
    let arcAmplitude: Double
    let arcBaseY: Double
    let traversalSeconds: Double
    let screenWidth: Int
    let screenHeight: Int
    
    let illuminatedFraction: Double
    let waxing: Bool
    let textureImage: CGImage?
    
    init(screenWidth: Int,
         screenHeight: Int,
         buildingMaxHeight: Int,
         log: OSLog,
         minRadius: Int = 15,
         maxRadius: Int = 60,
         traversalSeconds: Double = 3600.0) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.traversalSeconds = traversalSeconds
        self.movingLeftToRight = Moon.referenceLatitude >= 0.0
        
        let boundedMin = max(5, min(1000, minRadius))
        let boundedMax = max(boundedMin, min(1200, maxRadius))
        let maxRLimitFromScreen = Int(0.2 * Double(min(screenWidth, screenHeight)))
        let allowedMaxR = min(boundedMax, maxRLimitFromScreen)
        self.radius = Int.random(in: boundedMin...allowedMaxR)
        
        let minBaseUnclamped = buildingMaxHeight + self.radius + 10
        let minBase = max(minBaseUnclamped, self.radius + 10)
        let maxBaseCandidate = minBase + Int(0.10 * Double(screenHeight))
        let maxBaseAllowed = screenHeight - self.radius - 10
        let baseUpper = min(maxBaseCandidate, maxBaseAllowed)
        let chosenBase = (baseUpper >= minBase) ? Int.random(in: minBase...baseUpper) : minBase
        self.arcBaseY = Double(chosenBase)
        
        let verticalHeadroom = Double(screenHeight - self.radius) - self.arcBaseY - 10.0
        let suggested = 0.15 * Double(screenHeight)
        let minAmp = 20.0
        self.arcAmplitude = min(max(minAmp, suggested), max(0.0, verticalHeadroom))
        
        let phaseDate = Moon.midnightInAustin()
        let (fraction, waxingFlag) = Moon.computePhase(on: phaseDate)
        self.illuminatedFraction = fraction
        self.waxing = waxingFlag
        
        self.textureImage = MoonTexture.createMoonTexture(diameter: self.radius * 2)
        
        os_log("Moon init r=%{public}d frac=%.3f waxing=%{public}@ dir=%{public}@ dur=%.0fs",
               log: log, type: .info,
               self.radius,
               self.illuminatedFraction,
               self.waxing ? "true" : "false",
               self.movingLeftToRight ? "L->R" : "R->L",
               self.traversalSeconds)
    }
    
    func currentCenter(now: Date = Date()) -> CGPoint {
        let cal = Calendar(identifier: .gregorian)
        let tz = TimeZone.current
        let comps = cal.dateComponents(in: tz, from: now)
        let seconds = Double((comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0))
        let loop = seconds.truncatingRemainder(dividingBy: traversalSeconds)
        let progress = loop / traversalSeconds
        let usableWidth = Double(screenWidth - 2 * radius)
        let baseX = Double(radius)
        let x = movingLeftToRight ? (progress * usableWidth + baseX)
                                  : ((1.0 - progress) * usableWidth + baseX)
        let y = arcBaseY + arcAmplitude * sin(Double.pi * progress)
        return CGPoint(x: x, y: y)
    }
    
    private static func midnightInAustin(reference: Date = Date()) -> Date {
        let tz = TimeZone(identifier: "America/Chicago")!
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: tz, from: reference)
        comps.hour = 0; comps.minute = 0; comps.second = 0; comps.nanosecond = 0
        comps.timeZone = tz
        return cal.date(from: comps)!
    }
    
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
        let fraction = 0.5 * (1.0 - cos(phaseAngle))
        let waxing = age < (synodicMonthDays / 2.0)
        return (min(max(fraction, 0.0), 1.0), waxing)
    }
}
