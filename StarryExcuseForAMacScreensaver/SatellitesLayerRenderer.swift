import Foundation
import CoreGraphics
import os
import QuartzCore
import Darwin   // For explicit access to math functions like log()
import simd

// Simple satellite renderer: spawns small bright points that traverse the sky
// horizontally (either direction) at a fixed speed, at random vertical positions
// above the skyline (upper ~70% of screen). Layer emits sprites per frame.
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
    
    // Instrumentation
    private var updateCount: UInt64 = 0
    
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
        os_log("Satellites init: avg=%{public}.2fs speed=%{public}.1f size=%{public}.1f brightness=%{public}.2f trailing=%{public}@ decay=%{public}.3f",
               log: log, type: .info, self.avgSpawnSeconds, Double(self.speed), Double(self.sizePx), Double(self.brightness), self.trailing ? "on" : "off", Double(self.trailDecay))
    }
    
    // MARK: - Public reconfiguration
    
    /// Enable or disable the renderer. Disabling clears any existing satellites.
    func setEnabled(_ enabled: Bool) {
        if enabled == isEnabled { return }
        isEnabled = enabled
        if !enabled {
            satellites.removeAll()
            os_log("Satellites disabled: clearing active satellites", log: log, type: .info)
        } else {
            os_log("Satellites enabled", log: log, type: .info)
            scheduleNextSpawn()
        }
    }
    
    /// Convenience to fully reset, disable, and clear state.
    func resetAndDisable() {
        satellites.removeAll()
        isEnabled = false
        os_log("Satellites resetAndDisable: cleared and disabled", log: log, type: .info)
    }
    
    /// Reset satellites and timers (preserves current parameter values and enabled state).
    func reset() {
        satellites.removeAll()
        scheduleNextSpawn()
        os_log("Satellites reset: cleared and rescheduled next spawn", log: log, type: .info)
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
                os_log("Satellites param changed: avgSpawnSeconds=%{public}.2f", log: log, type: .info, clamped)
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
        os_log("Satellites: next spawn in %{public}.2fs", log: log, type: .debug, timeUntilNextSpawn)
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
        os_log("Satellites spawn: dir=%{public}@ y=%{public}.1f speed=%{public}.1f size=%{public}.1f",
               log: log, type: .debug, fromLeft ? "L→R" : "R→L", Double(y), Double(speed), Double(sizePx))
    }
    
    // MARK: - Emission to GPU
    
    // Advance simulation, emit sprites for this frame, and compute keep factor for trails.
    // keepFactor = trailing ? (trailDecay^dt) : 0
    func update(dt: CFTimeInterval) -> ([SpriteInstance], Float) {
        updateCount &+= 1
        let logThis = (updateCount <= 5) || (updateCount % 120 == 0)
        
        // If disabled, just clear state and request texture clear (keep 0)
        guard isEnabled else {
            satellites.removeAll()
            if logThis { os_log("Satellites update: disabled -> clear layer", log: log, type: .info) }
            return ([], 0.0)
        }
        
        // Advance satellites & prune
        var idx = 0
        let dtf = CGFloat(dt)
        var removed = 0
        while idx < satellites.count {
            satellites[idx].x += satellites[idx].vx * dtf
            if satellites[idx].vx > 0 && satellites[idx].x - satellites[idx].size > CGFloat(width) {
                satellites.remove(at: idx)
                removed += 1
                continue
            } else if satellites[idx].vx < 0 && satellites[idx].x + satellites[idx].size < 0 {
                satellites.remove(at: idx)
                removed += 1
                continue
            }
            idx += 1
        }
        
        // Spawning
        timeUntilNextSpawn -= dt
        while timeUntilNextSpawn <= 0 {
            spawn()
            scheduleNextSpawn()
            break
        }
        
        var sprites: [SpriteInstance] = []
        for sat in satellites {
            let half = Float(sat.size * 0.5)
            let b = Float(sat.brightness)
            // Premultiplied RGBA gray (alpha=1)
            let colorPremul = SIMD4<Float>(b, b, b, 1.0)
            sprites.append(SpriteInstance(centerPx: SIMD2<Float>(Float(sat.x), Float(sat.y)),
                                          halfSizePx: SIMD2<Float>(half, half),
                                          colorPremul: colorPremul,
                                          shape: .rect))
        }
        
        let keep: Float = trailing ? Float(pow(Double(trailDecay), dt)) : 0.0
        if logThis {
            os_log("Satellites update: active=%{public}d sprites=%{public}d keep=%{public}.3f removed=%{public}d",
                   log: log, type: .info, satellites.count, sprites.count, Double(keep), removed)
        }
        return (sprites, max(0.0, min(1.0, keep)))
    }
}
