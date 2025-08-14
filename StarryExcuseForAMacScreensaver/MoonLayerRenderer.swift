import Foundation
import CoreGraphics
import os

// Handles drawing the moon onto a transparent context, independent of the
// evolving star/building field. Supports being called infrequently (e.g. once
// per second) while the base field continues to accumulate.
final class MoonLayerRenderer {
    private let skyline: Skyline
    private let log: OSLog
    private let brightBrightness: CGFloat
    private let darkBrightness: CGFloat
    
    // internal reuse
    private var frameCounter: Int = 0
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    
    // Dynamic oversizing: for the dark minority crescent (gibbous phases) we expand
    // the side rectangle outward toward the limb so any bright fringe is fully
    // covered. Previously this was a fixed constant (1.25). We now scale it
    // linearly with moon diameter:
    //   diameten
    //   diameter >= 150 px  -> 4.00
    //   in-between          -> linear interpolation
    // This preserves detail for small moons while preventing residual bright rims
    // on large moons where sub‑pixel antialiasing differences are more visible.
    private func darkMinorityOversize(forDiameter d: CGFloat) -> CGFloat {
        let dMin: CGFloat = 40.0
        let dMax: CGFloat = 150.0
        let oMin: CGFloat = 1.25
        let oMax: CGFloat = 4.0
        if d <= dMin { return oMin }
        if d >= dMax { return oMax }
        let t = (d - dMin) / (dMax - dMin)
        return oMin + t * (oMax - o
