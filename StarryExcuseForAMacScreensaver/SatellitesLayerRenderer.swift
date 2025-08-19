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
    
    // MARK: - Public configuration interface
    
    /// Whether the layer is actively rendering. Disabling clears existing satellites.
    private(set) var isEnabled: Bool = true
    
    /// Average seconds between spawns (modifiable at runtime).
    private var avgSpawnSeconds: Double
    
    /// Base horizontal speed (points / second).
    private var speed: CGFloat
    /// Base size (pixels) of each satellite square.
    private var sizePx: CGFloat
    /// Base brightness (0-1) prior to per-satellite random variation.
    private var brightness: CGFloat
    /// Whether to leave trails (alpha-faded decay)
    private var trailing: Bool
    /// Per-second decay factor (0 = instant disappear, 0.999 ~ slow fade)
    private var trailDecay: CGFloat
    
    private var satellites: [Satellite] = []
    
    private let width: Int
    private let height: Int
    private let log: OSLog
    
    private var timeUntilNextSpawn: Double = 0.0
    private var rng = SystemRandomNumberGenerator()
    
    // MARK: - Init
    
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
    
    // MARK: - Public reconfiguration
    
    /// Enable or disable the renderer. Disabling clears any existing satellites.
    func setEnabled(_ enabled: Bool) {
        if enabled == isEnabled { return }
        isEnabled = enabled
        if !enabled {
            satellites.removeAll()
        } else {
            scheduleNextSpawn()
        }
    }
    
    /// Convenience to fully reset, disable, and clear state.
    func resetAndDisable() {
        satellites.removeAll()
        isEnabled = false
    }
    
    /// Reset satellites and timers (preserves current parameter values and enabled state).
    func reset() {
        satellites.removeAll()
        scheduleNextSpawn()
    }
    
    /// Update runtime parameters. Any nil parameter is left unchanged.
    /// If avgSpawnSeconds changes, next spawn time is rescheduled to reflect new cadence.
    func updateParameters(avgSpawnSeconds: Double? = nil,
                          speed: CGFloat? = nil,
                          size: CGFloat? = nil,
                          brightness: CGFloat? = nil,
                          trailing: Bool? = nil,
                          trailDecay: CGFloat? = nil) {
        var reschedule = false
        
        if let a = avgSpawnSeconds {
            let clamped = max(0.05, a)
            if clamped != self.avgSpawnSeconds {
                self.avgSpawnSeconds = clamped
                reschedule = true
            }
        }
        if let s = speed {
            self.speed = max(1.0, s)
        }
        if let sz = size {
            self.sizePx = max(1.0, sz)
        }
        if let b = brightness {
            self.brightness = min(max(0.0, b), 1.0)
        }
        if let t = trailing {
            self.trailing = t
        }
        if let td = trailDecay {
            self.trailDecay = min(max(0.0, td), 0.999)
        }
        if reschedule {
            scheduleNextSpawn()
        }
    }
    
    // MARK: - Private helpers
    
    private func scheduleNextSpawn() {
        guard isEnabled else { return }
        // Exponential distribution with mean avgSpawnSeconds.
        // Use Darwin.log to avoid shadowing by the OSLog property named 'log'.
        let u = Double.random(in: 0.00001...0.99999, using: &rng)
        timeUntilNextSpawn = -Darwin.log(1 - u) * avgSpawnSeconds
    }
    
    private func spawn() {
        guard isEnabled else { return }
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
    
    // MARK: - Rendering
    
    func update(into context: CGContext, dt: CFTimeInterval) {
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        
        // If disabled, clear and skip.
        guard isEnabled else {
            context.clear(fullRect)
            return
        }
        
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
                context.fill(fullRect)
                context.setBlendMode(.normal)
            }
            context.restoreGState()
        } else {
            context.clear(fullRect)
        }
        
        // Advance satellites & prune
        var idx = 0
        let dtf = CGFloat(dt)
        while idx < satellites.count {
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
        
        // Spawning
        timeUntilNextSpawn -= dt
        while timeUntilNextSpawn <= 0 {
            spawn()
            scheduleNextSpawn()
            // Keep timeUntilNextSpawn simple — no carryover of overshoot
            break
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
            context.setFillColor(CGColor(red: sat.brightness,
                                         green: sat.brightness,
                                         blue: sat.brightness,
                                         alpha: 1.0))
            context.fill(rect)
        }
        context.restoreGState()
    }
}
