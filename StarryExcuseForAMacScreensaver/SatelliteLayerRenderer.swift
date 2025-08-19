import Foundation
import CoreGraphics
import QuartzCore
import os

/// Simple first-pass satellite renderer.
/// Satellites are tiny bright dots that traverse the sky in straight lines
/// (left->right or right->left) at a constant speed. They are short-lived, not
/// persistent, and the layer is redrawn each frame.
final class SatelliteLayerRenderer {
    
    private struct Satellite {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var lifetime: CFTimeInterval
        var age: CFTimeInterval
    }
    
    private let width: Int
    private let height: Int
    private let avgSeconds: Double
    private let speed: CGFloat
    private let size: CGFloat
    private let brightness: CGFloat
    private let maxConcurrent: Int
    private let log: OSLog
    
    private var satellites: [Satellite] = []
    private var rng = SystemRandomNumberGenerator()
    
    // Accumulator for spawn timing (Poisson-ish approach)
    private var spawnAccumulator: Double = 0
    
    init(width: Int,
         height: Int,
         avgSeconds: Double,
         speed: CGFloat,
         size: CGFloat,
         brightness: CGFloat,
         maxConcurrent: Int,
         log: OSLog) {
        self.width = width
        self.height = height
        self.avgSeconds = max(0.5, avgSeconds)
        self.speed = speed
        self.size = size
        self.brightness = max(0.05, min(1.0, brightness))
        self.maxConcurrent = max(1, maxConcurrent)
        self.log = log
    }
    
    func reset() {
        satellites.removeAll()
        spawnAccumulator = 0
    }
    
    func update(into context: CGContext, dt: CFTimeInterval) {
        guard width > 0, height > 0 else { return }
        
        // Spawn logic: expected one every avgSeconds (Poisson style)
        spawnAccumulator += dt
        let spawnProbability = dt / avgSeconds
        if satellites.count < maxConcurrent &&
            Double.random(in: 0...1, using: &rng) < spawnProbability {
            spawnSatellite()
        }
        
        // Update satellites
        var alive: [Satellite] = []
        alive.reserveCapacity(satellites.count)
        for var s in satellites {
            s.age += dt
            s.x += s.vx * CGFloat(dt)
            if s.age < s.lifetime &&
                s.x > -50 && s.x < CGFloat(width) + 50 {
                alive.append(s)
            }
        }
        satellites = alive
        
        draw(into: context)
    }
    
    private func spawnSatellite() {
        // Randomly decide direction
        let leftToRight = Bool.random(using: &rng)
        let yMin = CGFloat(height) * 0.15
        let yMax = CGFloat(height) * 0.82
        let y = CGFloat.random(in: yMin...yMax, using: &rng)
        let startX: CGFloat = leftToRight ? -20 : CGFloat(width) + 20
        let vx: CGFloat = (leftToRight ? 1 : -1) * speed
        // Lifetime enough to cross screen plus margin
        let distance = CGFloat(width) + 40
        let lifetime = CFTimeInterval(distance / speed) * 1.1
        let sat = Satellite(x: startX,
                            y: y,
                            vx: vx,
                            lifetime: lifetime,
                            age: 0)
        satellites.append(sat)
    }
    
    private func draw(into context: CGContext) {
        guard !satellites.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        
        let alpha = brightness
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        
        for s in satellites {
            let rect = CGRect(x: s.x - size * 0.5,
                              y: CGFloat(height) - s.y - size * 0.5,
                              width: size,
                              height: size)
            context.fill(rect)
        }
    }
}
