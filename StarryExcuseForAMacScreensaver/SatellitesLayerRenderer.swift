import Foundation
import CoreGraphics
import os
import QuartzCore
import Darwin   // For explicit access to math functions like log()

// Simple satellite renderer: spawns small bright points that traverse the sky
// horizontally (either direction) at a fixed speed, at random vertical positions
// above the skyline (upper ~70% of screen). Layer is redrawn each frame.
final class SatellitesLayerRenderer {
    
    private struct Satellite {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var size: CGFloat
        var brightness: CGFloat
    }
    
    private var satellites: [Satellite] = []
    
    private let width: Int
    private let height: Int
    private let log: OSLog
    private let avgSpawnSeconds: Double
    private let speed: CGFloat
    private let sizePx: CGFloat
    private let brightness: CGFloat
    private let trailing: Bool
    private let trailDecay: CGFloat
    
    private var timeUntilNextSpawn: Double = 0.0
    private var rng = SystemRandomNumberGenerator()
    
    init(width: Int,
         height: Int,
         log: OSLog,
         avgSpawnSeconds: Double,
         speed: CGFloat,
         size: CGFloat,
         brightness: CGFloat,
         trailing: Bool,
         trailDecay: CGFloat) {
        self.width = width
        self.height = height
        self.log = log
        self.avgSpawnSeconds = max(0.05, avgSpawnSeconds)
        self.speed = speed
        self.sizePx = max(1.0, size)
        self.brightness = min(max(0.0, brightness), 1.0)
        self.trailing = trailing
        self.trailDecay = min(max(0.0, trailDecay), 0.999)
        scheduleNextSpawn()
    }
    
    func reset() {
        satellites.removeAll()
        scheduleNextSpawn()
    }
    
    private func scheduleNextSpawn() {
        // Exponential distribution with mean avgSpawnSeconds.
        // Use Darwin.log to avoid shadowing by the OSLog property named 'log'.
        let u = Double.random(in: 0.00001...0.99999, using: &rng)
        timeUntilNextSpawn = -Darwin.log(1 - u) * avgSpawnSeconds
    }
    
    private func spawn() {
        let fromLeft = Bool.random(using: &rng)
        // Constrain y so satellites stay above likely building tops (upper 70% of screen)
        let yMin = CGFloat(height) * 0.30
        let yMax = CGFloat(height) * 0.95
        let y = CGFloat.random(in: yMin...yMax, using: &rng)
        let x = fromLeft ? -sizePx : CGFloat(width) + sizePx
        let vx = (fromLeft ? 1.0 : -1.0) * speed
        let s = Satellite(x: x,
                          y: y,
                          vx: vx,
                          size: sizePx,
                          brightness: brightness * CGFloat.random(in: 0.8...1.05, using: &rng))
        satellites.append(s)
    }
    
    func update(into context: CGContext, dt: CFTimeInterval) {
        // Apply trail fade if enabled (done here so engine doesn't need to decide)
        if trailing {
            // DestinationOut fill to fade older pixels
            context.saveGState()
            let fadeAlpha: CGFloat
            // Compute per-frame fade from per-second decay factor
            // brightness(t+dt) = decay^dt * brightness(t) -> fade = 1 - decay^dt
            let perFrameKeep = pow(trailDecay, CGFloat(dt))
            fadeAlpha = 1.0 - perFrameKeep
            if fadeAlpha > 0 {
                context.setBlendMode(.destinationOut)
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: fadeAlpha))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setBlendMode(.normal)
            }
            context.restoreGState()
        } else {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        }
        
        var idx = 0
        while idx < satellites.count {
            let dtf = CGFloat(dt)
            satellites[idx].x += satellites[idx].vx * dtf
            if satellites[idx].vx > 0 && satellites[idx].x - satellites[idx].size > CGFloat(width) {
                satellites.remove(at: idx)
                continue
            } else if satellites[idx].vx < 0 && satellites[idx].x + satellites[idx].size < 0 {
                satellites.remove(at: idx)
                continue
            }
            idx += 1
        }
        
        timeUntilNextSpawn -= dt
        while timeUntilNextSpawn <= 0 {
            spawn()
            scheduleNextSpawn()
            timeUntilNextSpawn -= 0 // no overshoot accumulation; keep loop simple
        }
        
        drawSatellites(into: context)
    }
    
    private func drawSatellites(into context: CGContext) {
        context.saveGState()
        for sat in satellites {
            let rect = CGRect(x: sat.x - sat.size * 0.5,
                              y: sat.y - sat.size * 0.5,
                              width: sat.size,
                              height: sat.size)
            // Simple white-ish square; could later add a 2x2 cross or slight glow
            context.setFillColor(CGColor(red: sat.brightness,
                                         green: sat.brightness,
                                         blue: sat.brightness,
                                         alpha: 1.0))
            context.fill(rect)
        }
        context.restoreGState()
    }
}
