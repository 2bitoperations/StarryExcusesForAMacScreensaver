import Foundation
import CoreGraphics
import os
import QuartzCore
import Darwin   // For explicit access to math functions like log()
import simd

// Simple satellite renderer: spawns small bright points that traverse the sky
// horizontally (either direction) at a fixed speed, at random vertical positions
// above the skyline (upper ~70% of screen). Layer emits one "head" sprite per
// active satellite per frame; persistent trail is produced by GPU decay.
//
// 2025 Update: Spawn vertical band is now dynamically clamped so satellites
// always spawn ABOVE the top of the flasher. Caller should provide flasher
// geometry via setFlasherInfo(centerY:radius:) each frame (or when it changes).
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
    /// Base size (pixels) of each satellite circle (diameter).
    private var sizePx: CGFloat
    /// Base brightness (0-1) prior to per-satellite random variation.
    private var brightness: CGFloat
    /// Whether to leave trails (decay handled by GPU; this controls CPU-side keep output only)
    private var trailing: Bool
    /// Per-second decay factor (0 = instant disappear, 0.999 ~ slow fade). Used to compute keep return value.
    private var trailDecay: CGFloat
    /// Debug: show spawn vertical band bounds.
    private var debugShowSpawnBounds: Bool
    
    /// Dynamic flasher information (used to ensure satellites spawn above flasher top).
    private var flasherCenterY: CGFloat?
    private var flasherRadius: CGFloat?
    /// Extra vertical gap (pixels) to keep between flasher top and satellite spawn area.
    private let flasherVerticalGap: CGFloat = 4.0
    
    /// Active satellites.
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
         trailDecay: CGFloat,
         debugShowSpawnBounds: Bool) {
        self.width = width
        self.height = height
        self.log = log
        self.avgSpawnSeconds = max(0.05, avgSpawnSeconds)
        self.speed = speed
        self.sizePx = max(1.0, size)
        self.brightness = min(max(0.0, brightness), 1.0)
        self.trailing = trailing
        self.trailDecay = min(max(0.0, trailDecay), 0.999)
        self.debugShowSpawnBounds = debugShowSpawnBounds
        scheduleNextSpawn()
        os_log("Satellites init: avg=%{public}.2fs speed=%{public}.1f size=%{public}.1f brightness=%{public}.2f trailing=%{public}@ decay=%{public}.3f showBounds=%{public}@",
               log: log, type: .info, self.avgSpawnSeconds, Double(self.speed), Double(self.sizePx), Double(self.brightness), self.trailing ? "on" : "off", Double(self.trailDecay), debugShowSpawnBounds ? "true" : "false")
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
                          trailDecay: CGFloat? = nil,
                          debugShowSpawnBounds: Bool? = nil) {
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
        if let dbg = debugShowSpawnBounds {
            self.debugShowSpawnBounds = dbg
        }
        if reschedule {
            scheduleNextSpawn()
        }
    }
    
    /// Provide current flasher geometry so satellites can spawn above it.
    /// Call this each frame (or whenever flasher moves). Pass nil radius to clear.
    func setFlasherInfo(centerY: CGFloat, radius: CGFloat) {
        flasherCenterY = centerY
        flasherRadius = max(0.0, radius)
    }
    
    /// Clear flasher info (satellites revert to legacy band).
    func clearFlasherInfo() {
        flasherCenterY = nil
        flasherRadius = nil
    }
    
    // MARK: - Private helpers
    
    private func scheduleNextSpawn() {
        guard isEnabled else { return }
        // Exponential distribution with mean avgSpawnSeconds.
        let u = Double.random(in: 0.00001...0.99999, using: &rng)
        timeUntilNextSpawn = -Darwin.log(1 - u) * avgSpawnSeconds
        os_log("Satellites: next spawn in %{public}.2fs", log: log, type: .debug, timeUntilNextSpawn)
    }
    
    // Compute the current vertical spawn band (inclusive) taking flasher into account.
    // Returns (minY, maxY). Coordinate system origin is at top (y=0).
    //
    // REQUIREMENT: The entire band must be ABOVE (visually higher than) the flasher,
    // meaning every possible satellite center Y we choose yields a satellite whose
    // bottom edge remains strictly above (flasherTop - flasherVerticalGap).
    //
    // For a satellite of diameter D, its bottom edge = centerY + D/2.
    // We enforce: centerY_max + D/2 <= flasherTop - gap  => centerY_max <= flasherTop - gap - D/2
    // Additionally, we clamp yMin to never exceed that same limit so the whole band
    // is above the flasher, not just its lower edge.
    private func currentSpawnBand(satelliteDiameter: CGFloat) -> (CGFloat, CGFloat) {
        // Legacy baseline band (was 30%..95%). We widen upward a bit to allow more sky if clamped.
        var yMin = CGFloat(height) * 0.05      // nearer the top of screen
        var yMax = CGFloat(height) * 0.95      // nearer the bottom
        
        if let cy = flasherCenterY, let r = flasherRadius {
            let flasherTop = cy - r
            // Max allowed center Y so entire satellite stays above flasher (plus gap):
            let limitMaxCenter = flasherTop - satelliteDiameter * 0.5 - flasherVerticalGap
            yMax = min(yMax, limitMaxCenter)
            // Ensure upper edge (yMin) also lies above same limit; this collapses band upward if needed.
            if yMin > yMax {
                // Collapse to a single permissible line (degenerate band).
                yMin = yMax
            } else if yMin > limitMaxCenter {
                yMin = limitMaxCenter
            }
        }
        // Clamp to screen bounds.
        yMin = max(0, min(CGFloat(height), yMin))
        yMax = max(0, min(CGFloat(height), yMax))
        // Final safety: maintain ordering.
        if yMin > yMax {
            yMin = yMax
        }
        return (yMin, yMax)
    }
    
    private func spawn() {
        guard isEnabled else { return }
        let fromLeft = Bool.random(using: &rng)
        
        // Determine spawn band respecting flasher (if provided).
        let (bandMin, bandMax) = currentSpawnBand(satelliteDiameter: sizePx)
        let y: CGFloat
        if bandMax >= bandMin {
            y = CGFloat.random(in: bandMin...bandMax, using: &rng)
        } else {
            y = bandMin   // fallback (should not happen)
        }
        
        let x = fromLeft ? -sizePx : CGFloat(width) + sizePx
        let vx = (fromLeft ? 1.0 : -1.0) * speed
        let s = Satellite(x: x,
                          y: y,
                          vx: vx,
                          size: sizePx,
                          brightness: brightness * CGFloat.random(in: 0.8...1.05, using: &rng))
        satellites.append(s)
        let (finalMin, finalMax) = (bandMin, bandMax)
        os_log("Satellites spawn: dir=%{public}@ y=%{public}.1f band=[%.1f, %.1f] speed=%{public}.1f size=%{public}.1f activeNow=%{public}d flasherTop=%{public}@",
               log: log, type: .debug,
               fromLeft ? "L→R" : "R→L",
               Double(y),
               Double(finalMin), Double(finalMax),
               Double(speed),
               Double(sizePx),
               satellites.count,
               (flasherCenterY != nil && flasherRadius != nil) ? "yes" : "no")
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
            break   // emit at most one new satellite per frame; loop kept for robustness
        }
        
        var sprites: [SpriteInstance] = []
        sprites.reserveCapacity(satellites.count + (debugShowSpawnBounds ? 1 : 0))
        
        // Emit only the head for each active satellite.
        for sat in satellites {
            let half = Float(sat.size * 0.5)
            let b = Float(sat.brightness)
            let colorPremul = SIMD4<Float>(b, b, b, 1.0)
            sprites.append(
                SpriteInstance(centerPx: SIMD2<Float>(Float(sat.x), Float(sat.y)),
                               halfSizePx: SIMD2<Float>(half, half),
                               colorPremul: colorPremul,
                               shape: .circle)
            )
        }
        
        // Debug vertical band bounds (y-range).
        if debugShowSpawnBounds {
            let (bandMin, bandMax) = currentSpawnBand(satelliteDiameter: sizePx)
            let minY = min(bandMin, bandMax)
            let maxY = max(bandMin, bandMax)
            if maxY >= minY {
                let rect = CGRect(x: 0,
                                  y: minY,
                                  width: CGFloat(width),
                                  height: max(1.0, maxY - minY))
                // Cyan outline
                let alpha: CGFloat = 0.70
                let r: CGFloat = 0.05
                let g: CGFloat = 0.85
                let b: CGFloat = 1.0
                let premul = SIMD4<Float>(Float(r * alpha),
                                          Float(g * alpha),
                                          Float(b * alpha),
                                          Float(alpha))
                if let sprite = makeRectOutlineSprite(rect: rect, colorPremul: premul) {
                    sprites.append(sprite)
                }
            }
        }
        
        let keep: Float = trailing ? Float(pow(Double(trailDecay), dt)) : 0.0
        if logThis {
            let flasherState: String
            if let cy = flasherCenterY, let r = flasherRadius {
                let top = cy - r
                flasherState = String(format: "yes(top=%.1f)", Double(top))
            } else {
                flasherState = "no"
            }
            os_log("Satellites update: active=%{public}d sprites=%{public}d keep=%{public}.3f removed=%{public}d flasher=%{public}@ dbgBounds=%{public}@",
                   log: log, type: .info, satellites.count, sprites.count, Double(keep), removed, flasherState, debugShowSpawnBounds ? "yes" : "no")
        }
        return (sprites, max(0.0, min(1.0, keep)))
    }
}
