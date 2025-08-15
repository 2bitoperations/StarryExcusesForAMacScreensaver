import Foundation
import CoreGraphics
import QuartzCore
import os

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
    
    // Config (dynamic; may be replaced by new renderer if changed)
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
    
    // For Poisson process
    private var timeAccumulator: CFTimeInterval = 0
    
    // Spawn constraints
    private var safeMinY: CGFloat = 0
    private var spawnAttemptsPerFrame = 8
    
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
    }
    
    func reset() {
        active.removeAll()
        timeAccumulator = 0
    }
    
    private func computeSafeMinY() {
        if let sk = skyline {
            // Buildings rise from y=0 upward – keep path completely above buildingMaxHeight + margin
            safeMinY = CGFloat(sk.buildingMaxHeight + 4)
        } else {
            safeMinY = 0
        }
    }
    
    // MARK: - Update
    
    func update(into ctx: CGContext, dt: CFTimeInterval) {
        // Apply decay (multiplicative) to existing layer to fade trails
        applyTrailDecay(into: ctx)
        
        spawnIfNeeded(dt: dt)
        
        // Update existing stars
        for i in 0..<active.count {
            var s = active[i]
            s.advance(dt: dt)
            active[i] = s
        }
        
        // Remove finished
        active.removeAll { $0.done }
        
        // Draw each active star (additive-ish by drawing bright strokes)
        for s in active {
            drawStar(s, into: ctx)
        }
        
        // Debug overlay
        if debugShowSpawnBounds {
            drawSpawnBounds(into: ctx)
        }
    }
    
    // MARK: - Decay
    
    private func applyTrailDecay(into ctx: CGContext) {
        // Multiply existing pixels by trailDecay by filling black with alpha = (1 - trailDecay)
        ctx.saveGState()
        let alpha = 1.0 - trailDecay
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: alpha))
        ctx.setBlendMode(.normal)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }
    
    // MARK: - Spawning
    
    private func spawnIfNeeded(dt: CFTimeInterval) {
        guard avgSeconds > 0 else { return }
        // Poisson arrival: p = dt / mean
        let p = dt / avgSeconds
        if Double.random(in: 0...1, using: &rng) < p {
            attemptSpawn()
        }
    }
    
    private func attemptSpawn() {
        for _ in 0..<spawnAttemptsPerFrame {
            if let star = makeStar() {
                active.append(star)
                break
            }
        }
    }
    
    private func makeStar() -> ShootingStar? {
        let dir = pickDirection()
        let lengthJitter = baseLength * CGFloat.random(in: 0.85...1.15, using: &rng)
        let lifetime = CFTimeInterval(lengthJitter / speed)
        
        // Need head0 such that head0 - dir*length and head0 + dir*length are both within safe area
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
                let t = thickness
                return ShootingStar(head: head0,
                                    dir: dir,
                                    speed: speed,
                                    length: lengthJitter,
                                    thickness: max(0.5, t),
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
        
        // Slight downward tendency so stars drift toward horizon
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
            // Curated list
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
    
    // MARK: - Drawing
    
    private func drawStar(_ s: ShootingStar, into ctx: CGContext) {
        let head = s.head
        let tail = s.tailPosition()
        let dir = s.dir
        let len = s.length
        
        // Fade-in at start (first 15% lifetime)
        var brightnessFactor = s.brightness
        if s.age < s.lifetime * 0.15 {
            brightnessFactor *= CGFloat(s.age / (s.lifetime * 0.15))
        }
        
        // Segment-based rendering
        let segments = 18
        for i in 0..<segments {
            let t = CGFloat(i) / CGFloat(segments - 1) // 0 tail -> 1 head
            let px = tail.x + dir.dx * len * t
            let py = tail.y + dir.dy * len * t
            
            // Intensity falls off toward tail (quadratic)
            let intensity = brightnessFactor * pow(t, 2.0)
            
            // Thickness tapers: tail thinner
            let radius = (s.thickness * 0.3) + (s.thickness * 0.7 * t)
            
            // Color: head warm tint, tail white
            let warmHead = (r: CGFloat(1.0), g: CGFloat(0.95), b: CGFloat(0.85))
            let tailWhite = (r: CGFloat(1.0), g: CGFloat(1.0), b: CGFloat(1.0))
            let blend = t
            let r = tailWhite.r * (1 - blend) + warmHead.r * blend
            let g = tailWhite.g * (1 - blend) + warmHead.g * blend
            let b = tailWhite.b * (1 - blend) + warmHead.b * blend
            let alpha = min(1.0, max(0.0, intensity))
            
            ctx.setFillColor(CGColor(red: r * alpha,
                                     green: g * alpha,
                                     blue: b * alpha,
                                     alpha: alpha))
            let rect = CGRect(x: px - radius,
                              y: py - radius,
                              width: radius * 2,
                              height: radius * 2)
            ctx.fillEllipse(in: rect)
        }
    }
    
    private func drawSpawnBounds(into ctx: CGContext) {
        ctx.saveGState()
        let rect = CGRect(x: 0, y: safeMinY, width: CGFloat(width), height: CGFloat(height) - safeMinY)
        ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.35))
        ctx.setLineWidth(2)
        ctx.stroke(rect)
        ctx.restoreGState()
    }
}
