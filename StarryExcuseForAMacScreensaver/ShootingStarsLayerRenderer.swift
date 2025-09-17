import Foundation
import CoreGraphics
import QuartzCore
import os
import simd

// Direction modes
enum ShootingStarDirectionMode: Int {
    case random = 0
    case leftToRight = 1
    case rightToLeft = 2
    case topLeftToBottomRight = 3
    case topRightToBottomLeft = 4
}

// Single shooting star state
private struct ShootingStar {
    var head: CGPoint          // Current head position
    let dir: CGVector          // Unit direction (normalized)
    let speed: CGFloat         // px per second
    let length: CGFloat        // total visible length
    let thickness: CGFloat     // base thickness at head
    let brightness: CGFloat    // brightness factor
    let lifetime: CFTimeInterval
    var age: CFTimeInterval = 0
    
    mutating func advance(dt: CFTimeInterval) {
        age += dt
        let dist = speed * CGFloat(dt)
        head.x += dir.dx * dist
        head.y += dir.dy * dist
    }
    
    var done: Bool { age >= lifetime }
    
    func tailPosition() -> CGPoint {
        CGPoint(x: head.x - dir.dx * length,
                y: head.y - dir.dy * length)
    }
}

final class ShootingStarsLayerRenderer {
    private let width: Int
    private let height: Int
    private weak var skyline: Skyline?
    private let log: OSLog
    
    // Config
    private var avgSeconds: Double
    private var directionMode: ShootingStarDirectionMode
    private var baseLength: CGFloat
    private var speed: CGFloat
    private var thickness: CGFloat
    private var brightness: CGFloat
    private var trailDecay: CGFloat
    private var debugShowSpawnBounds: Bool
    
    private var active: [ShootingStar] = []
    private var rng = SystemRandomNumberGenerator()
    
    // Spawn constraints
    private var safeMinY: CGFloat = 0
    private var spawnAttemptsPerFrame = 8
    
    // Instrumentation
    private var updateCount: UInt64 = 0
    
    init(width: Int,
         height: Int,
         skyline: Skyline,
         log: OSLog,
         avgSeconds: Double,
         directionModeRaw: Int,
         length: CGFloat,
         speed: CGFloat,
         thickness: CGFloat,
         brightness: CGFloat,
         trailDecay: CGFloat,
         debugShowSpawnBounds: Bool) {
        self.width = width
        self.height = height
        self.skyline = skyline
        self.log = log
        self.avgSeconds = avgSeconds
        self.directionMode = ShootingStarDirectionMode(rawValue: directionModeRaw) ?? .random
        self.baseLength = length
        self.speed = speed
        self.thickness = thickness
        self.brightness = brightness
        self.trailDecay = trailDecay
        self.debugShowSpawnBounds = debugShowSpawnBounds
        computeSafeMinY()
        os_log("ShootingStarsLayerRenderer init: avg=%{public}.2fs speed=%{public}.1f len=%{public}.1f thick=%{public}.1f bright=%{public}.2f decay=%{public}.3f mode=%{public}d showBounds=%{public}@",
               log: log, type: .info, avgSeconds, Double(speed), Double(length), Double(thickness), Double(brightness), Double(trailDecay), directionMode.rawValue, debugShowSpawnBounds ? "true" : "false")
    }
    
    func reset() {
        active.removeAll()
        os_log("ShootingStarsLayerRenderer reset: cleared active stars", log: log, type: .info)
    }
    
    private func computeSafeMinY() {
        if let sk = skyline {
            // Keep paths fully above tops of buildings (+ margin)
            safeMinY = CGFloat(sk.buildingMaxHeight + 4)
        } else {
            safeMinY = 0
        }
        os_log("ShootingStarsLayerRenderer safeMinY set to %{public}.1f", log: log, type: .debug, Double(safeMinY))
    }
    
    // MARK: - Update
    
    // Advance simulation and emit sprite instances for this frame.
    // Returns (sprites, keepFactor) where keepFactor=trailDecay^dt, or 0 if trails disabled.
    func update(dt: CFTimeInterval) -> ([SpriteInstance], Float) {
        updateCount &+= 1
        let logThis = (updateCount <= 5) || (updateCount % 120 == 0)
        
        spawnIfNeeded(dt: dt)
        
        // Advance positions
        for i in 0..<active.count {
            var s = active[i]
            s.advance(dt: dt)
            active[i] = s
        }
        
        // Remove old
        let before = active.count
        active.removeAll { $0.done }
        let removed = before - active.count
        
        var sprites: [SpriteInstance] = []
        for s in active {
            appendStarSprites(s, into: &sprites)
        }
        
        // Append debug spawn bounds outline (drawn every frame so stable brightness despite decay)
        if debugShowSpawnBounds {
            if let boundsSprite = spawnBoundsSprite() {
                sprites.append(boundsSprite)
            }
        }
        
        let keepFactor: Float
        if trailDecay <= 0 { keepFactor = 0 }
        else {
            let k = pow(Double(trailDecay), dt)
            keepFactor = Float(max(0.0, min(1.0, k)))
        }
        
        if logThis {
            os_log("ShootingStars update: active=%{public}d spawnedSprites=%{public}d removed=%{public}d keep=%{public}.3f dbgBounds=%{public}@",
                   log: log, type: .info, active.count, sprites.count, removed, Double(keepFactor), debugShowSpawnBounds ? "yes" : "no")
        }
        return (sprites, keepFactor)
    }
    
    // MARK: - Spawn Bounds (Debug)
    
    // Computes a conservative rectangle where shooting star heads can spawn while keeping tails on-screen.
    private func spawnBoundsSprite() -> SpriteInstance? {
        let lenMax = baseLength * 1.15
        let margin: CGFloat = 4
        let minX = margin + lenMax
        let maxX = CGFloat(width) - margin - lenMax
        if minX >= maxX { return nil }
        let minY = max(safeMinY + margin + lenMax, safeMinY + 8)
        let maxY = CGFloat(height) - margin - lenMax
        if minY >= maxY { return nil }
        
        let rect = CGRect(x: minX,
                          y: minY,
                          width: maxX - minX,
                          height: maxY - minY)
        
        // Warm orange outline (premultiplied)
        let alpha: CGFloat = 0.85
        let r: CGFloat = 1.0
        let g: CGFloat = 0.55
        let b: CGFloat = 0.10
        let colorPremul = SIMD4<Float>(Float(r * alpha),
                                       Float(g * alpha),
                                       Float(b * alpha),
                                       Float(alpha))
        return makeRectOutlineSprite(rect: rect, colorPremul: colorPremul)
    }
    
    // MARK: - Spawning
    
    private func spawnIfNeeded(dt: CFTimeInterval) {
        guard avgSeconds > 0 else { return }
        let p = dt / avgSeconds
        if Double.random(in: 0...1, using: &rng) < p {
            attemptSpawn()
        }
    }
    
    private func attemptSpawn() {
        for _ in 0..<spawnAttemptsPerFrame {
            if let star = makeStar() {
                active.append(star)
                os_log("ShootingStars spawn: y=%{public}.1f dir=(%{public}.2f,%{public}.2f) len=%{public}.1f speed=%{public}.1f",
                       log: log, type: .debug,
                       Double(star.head.y), Double(star.dir.dx), Double(star.dir.dy), Double(star.length), Double(star.speed))
                break
            }
        }
    }
    
    private func makeStar() -> ShootingStar? {
        let dir = pickDirection()
        let lengthJitter = baseLength * CGFloat.random(in: 0.85...1.15, using: &rng)
        let lifetime = CFTimeInterval(lengthJitter / speed)
        
        // Head position constraints so both ends remain in safe area.
        let margin: CGFloat = 4
        let minX = margin + lengthJitter
        let maxX = CGFloat(width) - margin - lengthJitter
        if minX >= maxX { return nil }
        
        let minY = max(safeMinY + margin + lengthJitter, safeMinY + 8)
        let maxY = CGFloat(height) - margin - lengthJitter
        if minY >= maxY { return nil }
        
        for _ in 0..<10 {
            let hx = CGFloat.random(in: minX...maxX, using: &rng)
            let hy = CGFloat.random(in: minY...maxY, using: &rng)
            let head0 = CGPoint(x: hx, y: hy)
            let extremity1 = CGPoint(x: head0.x - dir.dx * lengthJitter,
                                     y: head0.y - dir.dy * lengthJitter)
            let extremity2 = CGPoint(x: head0.x + dir.dx * lengthJitter,
                                     y: head0.y + dir.dy * lengthJitter)
            if inside(extremity1) && inside(extremity2) {
                return ShootingStar(head: head0,
                                    dir: dir,
                                    speed: speed,
                                    length: lengthJitter,
                                    thickness: max(0.5, thickness),
                                    brightness: brightness,
                                    lifetime: lifetime)
            }
        }
        return nil
    }
    
    private func inside(_ p: CGPoint) -> Bool {
        if p.x < 0 || p.x >= CGFloat(width) { return false }
        if p.y < safeMinY || p.y >= CGFloat(height) { return false }
        return true
    }
    
    private func pickDirection() -> CGVector {
        func norm(_ dx: CGFloat, _ dy: CGFloat) -> CGVector {
            let len = sqrt(dx*dx + dy*dy)
            if len == 0 { return CGVector(dx: 1, dy: -0.3) }
            return CGVector(dx: dx/len, dy: dy/len)
        }
        switch directionMode {
        case .leftToRight:
            return addJitter(norm(1, -0.25))
        case .rightToLeft:
            return addJitter(norm(-1, -0.25))
        case .topLeftToBottomRight:
            return addJitter(norm(1, -1))
        case .topRightToBottomLeft:
            return addJitter(norm(-1, -1))
        case .random:
            let candidates: [CGVector] = [
                norm(1, -0.3),
                norm(-1, -0.3),
                norm(1, -0.8),
                norm(-1, -0.8),
                norm(0.8, -1),
                norm(-0.8, -1)
            ]
            let base = candidates.randomElement(using: &rng) ?? norm(1, -0.3)
            return addJitter(base)
        }
    }
    
    private func addJitter(_ v: CGVector) -> CGVector {
        let jitterAngle = CGFloat.random(in: -0.15...0.15, using: &rng)
        let cosA = cos(jitterAngle)
        let sinA = sin(jitterAngle)
        let dx = v.dx * cosA - v.dy * sinA
        let dy = v.dx * sinA + v.dy * cosA
        let len = sqrt(dx*dx + dy*dy)
        return CGVector(dx: dx/len, dy: dy/len)
    }
    
    // MARK: - Drawing emission
    
    private func appendStarSprites(_ s: ShootingStar, into sprites: inout [SpriteInstance]) {
        let tail = s.tailPosition()
        let dir = s.dir
        let len = s.length
        
        var brightnessFactor = s.brightness
        if s.age < s.lifetime * 0.15 {
            brightnessFactor *= CGFloat(s.age / (s.lifetime * 0.15))
        }
        
        let segments = 18
        for i in 0..<segments {
            let t = CGFloat(i) / CGFloat(segments - 1) // 0 tail -> 1 head
            let px = tail.x + dir.dx * len * t
            let py = tail.y + dir.dy * len * t
            
            let intensity = brightnessFactor * pow(t, 2.0)
            let radius = (s.thickness * 0.3) + (s.thickness * 0.7 * t)
            
            // Blend color from tail white to warm head
            let warmHead = (r: CGFloat(1.0), g: CGFloat(0.95), b: CGFloat(0.85))
            let tailWhite = (r: CGFloat(1.0), g: CGFloat(1.0), b: CGFloat(1.0))
            let blend = t
            let rr = tailWhite.r * (1 - blend) + warmHead.r * blend
            let gg = tailWhite.g * (1 - blend) + warmHead.g * blend
            let bb = tailWhite.b * (1 - blend) + warmHead.b * blend
            let alpha = min(1.0, max(0.0, intensity))
            
            let colorPremul = SIMD4<Float>(Float(rr * alpha), Float(gg * alpha), Float(bb * alpha), Float(alpha))
            sprites.append(SpriteInstance(centerPx: SIMD2<Float>(Float(px), Float(py)),
                                          halfSizePx: SIMD2<Float>(Float(radius), Float(radius)),
                                          colorPremul: colorPremul,
                                          shape: .circle))
        }
    }
}
