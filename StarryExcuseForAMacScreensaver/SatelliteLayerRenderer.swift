import Foundation
import CoreGraphics
import os
import QuartzCore

// A lightweight renderer for simple "satellite" dots that traverse the sky.
// For this first pass, satellites:
//  - Spawn frequently (avg every ~0.8s) to aid testing.
//  - Travel in straight lines either left->right or right->left.
//  - Appear at random altitudes in the upper portion of the sky (avoid buildings).
//  - Blink gently (sinusoidal brightness modulation) to mimic varying reflectivity.
//  - Are small 2-3px circles.
final class SatelliteLayerRenderer {
    
    private struct Satellite {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var size: CGFloat
        var baseBrightness: CGFloat
        var blinkPhase: CGFloat
        var created: CFTimeInterval
    }
    
    private var satellites: [Satellite] = []
    
    // Configuration (hard-coded defaults for now)
    private let avgSpawnSeconds: Double = 0.8          // > 1 per second
    private let minSpeed: CGFloat = 40.0               // px/sec
    private let maxSpeed: CGFloat = 80.0               // px/sec
    private let minSize: CGFloat = 2.0
    private let maxSize: CGFloat = 3.0
    private let minBrightness: CGFloat = 0.65
    private let maxBrightness: CGFloat = 0.95
    private let blinkPeriod: CFTimeInterval = 0.9      // seconds
    private let upperSkyPortion: CGFloat = 0.55        // y fraction (0=top) below which satellites may appear
    private let edgeSpawnInset: CGFloat = 10.0         // slight inset to avoid popping exactly on edge
    private let maxCount: Int = 40                     // safety cap
    
    private let width: Int
    private let height: Int
    private let log: OSLog
    
    private var timeAccumulator: CFTimeInterval = 0
    
    init(width: Int,
         height: Int,
         log: OSLog) {
        self.width = width
        self.height = height
        self.log = log
    }
    
    func reset() {
        satellites.removeAll()
        timeAccumulator = 0
    }
    
    func update(into ctx: CGContext, dt: CFTimeInterval) {
        guard width > 0, height > 0 else { return }
        
        spawnIfNeeded(dt: dt)
        updatePositions(dt: dt)
        draw(into: ctx, atTime: CACurrentMediaTime())
    }
    
    // MARK: - Spawning
    
    private func spawnIfNeeded(dt: CFTimeInterval) {
        // Poisson process: probability of one spawn within dt is dt / avg.
        var remainingDt = dt
        while remainingDt > 0 {
            // For stability if dt large, sub-step.
            let step = min(remainingDt, 0.25)
            let p = step / avgSpawnSeconds
            if Double.random(in: 0...1) < p {
                spawnOne()
            }
            remainingDt -= step
        }
    }
    
    private func spawnOne() {
        guard satellites.count < maxCount else { return }
        let goingRight = Bool.random()
        let y = CGFloat.random(in: 0.05 * CGFloat(height) ... upperSkyPortion * CGFloat(height))
        let speed = CGFloat.random(in: minSpeed...maxSpeed) * (goingRight ? 1 : -1)
        let size = CGFloat.random(in: minSize...maxSize)
        let brightness = CGFloat.random(in: minBrightness...maxBrightness)
        let xStart: CGFloat = goingRight ? -edgeSpawnInset : CGFloat(width) + edgeSpawnInset
        let blinkPhase = CGFloat.random(in: 0...(2 * .pi))
        let sat = Satellite(x: xStart,
                            y: y,
                            vx: speed,
                            size: size,
                            baseBrightness: brightness,
                            blinkPhase: blinkPhase,
                            created: CACurrentMediaTime())
        satellites.append(sat)
    }
    
    // MARK: - Update
    
    private func updatePositions(dt: CFTimeInterval) {
        let w = CGFloat(width)
        satellites = satellites.filter { sat in
            let newX = sat.x + sat.vx * CGFloat(dt)
            return newX > -40 && newX < w + 40
        }.map { sat in
            var s = sat
            s.x += s.vx * CGFloat(dt)
            return s
        }
    }
    
    // MARK: - Drawing
    
    private func draw(into ctx: CGContext, atTime t: CFTimeInterval) {
        for sat in satellites {
            let blink = 0.5 + 0.5 * sin( ( (t - sat.created) / blinkPeriod ) * 2 * .pi + Double(sat.blinkPhase) )
            let brightness = min(1.0, max(0.0, Double(sat.baseBrightness) * (0.6 + 0.4 * blink)))
            let color = CGColor(red: brightness, green: brightness, blue: brightness, alpha: 1.0)
            ctx.setFillColor(color)
            let rect = CGRect(x: sat.x - sat.size * 0.5,
                              y: sat.y - sat.size * 0.5,
                              width: sat.size,
                              height: sat.size)
            ctx.fillEllipse(in: rect)
        }
    }
}
