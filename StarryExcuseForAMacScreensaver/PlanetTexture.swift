import CoreGraphics
import Foundation

enum PlanetTexture {

    // MARK: - Public dispatch

    static func createTexture(for identity: PlanetIdentity, diameter: Int) -> CGImage? {
        switch identity {
        case .mercury: return scaleTexture(generateMercuryAlbedoMap(size: 64), size: 64, to: diameter)
        case .venus:   return scaleTexture(generateVenusAlbedoMap(size: 64),   size: 64, to: diameter)
        case .mars:    return scaleTexture(generateMarsAlbedoMap(size: 64),    size: 64, to: diameter)
        case .jupiter: return scaleTexture(generateJupiterAlbedoMap(size: 64), size: 64, to: diameter)
        case .saturn:  return createSaturnTexture(diameter: diameter)
        case .uranus:  return scaleTexture(generateUranusAlbedoMap(size: 64),  size: 64, to: diameter)
        case .neptune: return scaleTexture(generateNeptuneAlbedoMap(size: 64), size: 64, to: diameter)
        case .pluto:   return scaleTexture(generatePlutoAlbedoMap(size: 64),   size: 64, to: diameter)
        }
    }

    // Legacy entry point — kept for any remaining direct callers.
    static func createJupiterTexture(diameter: Int) -> CGImage? {
        return createTexture(for: .jupiter, diameter: diameter)
    }

    // MARK: - Scale helper

    private static func scaleTexture(_ data: [UInt8], size: Int, to diameter: Int) -> CGImage? {
        guard let baseImage = makeRGBAImage(width: size, height: size, data: data) else { return nil }
        if diameter == size { return baseImage }
        guard
            let ctx = CGContext(
                data: nil,
                width: diameter,
                height: diameter,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return baseImage }
        ctx.interpolationQuality = .none
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        return ctx.makeImage()
    }

    // MARK: - Mercury  (grey, cratered)

    private static func generateMercuryAlbedoMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv
                // Base grey with fine-grained noise for a dusty surface.
                let base = 0.52 + (pseudoNoise(x: x, y: y) - 0.5) * 0.22
                var r = base, g = base, b = base
                // Scatter a few darker crater-like splotches.
                let crater = pseudoNoise(x: x &* 7 &+ 3, y: y &* 11 &+ 5)
                if crater < 0.08 {
                    let depth = (0.08 - crater) / 0.08
                    r -= 0.18 * depth; g -= 0.18 * depth; b -= 0.18 * depth
                }
                let limb = limbDarkeningFactor(nx: nx, ny: ny)
                r = clamp(r * limb); g = clamp(g * limb); b = clamp(b * limb)
                let i = (y * size + x) * 4
                buf[i] = byte(r); buf[i+1] = byte(g); buf[i+2] = byte(b); buf[i+3] = 255
            }
        }
        return buf
    }

    // MARK: - Venus  (yellowish-tan, cloudy banding)

    private static func generateVenusAlbedoMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv
                // Soft horizontal banding from yellowish to tan.
                let bandNoise = pseudoNoise(x: x &* 3, y: y &* 5 &+ 13)
                let fy = Double(y) / Double(size)
                let band = 0.5 + 0.5 * sin(fy * Double.pi * 5.0 + bandNoise * 1.2)
                var r = 0.88 + band * 0.06
                var g = 0.76 + band * 0.04
                var b = 0.42 + band * 0.02
                let n = (pseudoNoise(x: x, y: y) - 0.5) * 0.06
                r = clamp(r + n); g = clamp(g + n * 0.8); b = clamp(b + n * 0.4)
                let limb = limbDarkeningFactor(nx: nx, ny: ny)
                r = clamp(r * limb); g = clamp(g * limb); b = clamp(b * limb)
                let i = (y * size + x) * 4
                buf[i] = byte(r); buf[i+1] = byte(g); buf[i+2] = byte(b); buf[i+3] = 255
            }
        }
        return buf
    }

    // MARK: - Mars  (reddish-orange with darker maria)

    private static func generateMarsAlbedoMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv
                var r = 0.76 + (pseudoNoise(x: x, y: y) - 0.5) * 0.10
                var g = 0.36 + (pseudoNoise(x: x &+ 100, y: y) - 0.5) * 0.06
                var b = 0.22 + (pseudoNoise(x: x, y: y &+ 100) - 0.5) * 0.04
                // Dark maria patches.
                let maria = pseudoNoise(x: x &* 5 &+ 7, y: y &* 3 &+ 11)
                if maria < 0.18 {
                    let d = (0.18 - maria) / 0.18
                    r -= 0.20 * d; g -= 0.10 * d; b -= 0.05 * d
                }
                // Tiny polar cap hint at top.
                if Double(y) < Double(size) * 0.08 {
                    let pct = 1.0 - Double(y) / (Double(size) * 0.08)
                    r = r * (1 - pct) + 0.96 * pct
                    g = g * (1 - pct) + 0.96 * pct
                    b = b * (1 - pct) + 0.98 * pct
                }
                let limb = limbDarkeningFactor(nx: nx, ny: ny)
                r = clamp(r * limb); g = clamp(g * limb); b = clamp(b * limb)
                let i = (y * size + x) * 4
                buf[i] = byte(r); buf[i+1] = byte(g); buf[i+2] = byte(b); buf[i+3] = 255
            }
        }
        return buf
    }

    // MARK: - Jupiter  (banded gas giant with Great Red Spot)

    private static let jupiterBandColors: [(r: Double, g: Double, b: Double)] = [
        (0.910, 0.835, 0.639),
        (0.831, 0.533, 0.227),
        (0.545, 0.396, 0.204),
        (0.890, 0.820, 0.620),
        (0.780, 0.490, 0.240),
        (0.910, 0.835, 0.639),
        (0.780, 0.440, 0.200),
        (0.890, 0.820, 0.600),
        (0.545, 0.380, 0.190),
        (0.870, 0.820, 0.640),
        (0.780, 0.710, 0.490),
    ]

    private static let jupiterBandStarts: [Int] = [0, 6, 11, 15, 21, 27, 33, 39, 45, 51, 57, 64]

    private static func jupiterBandColor(forRow y: Int, noise: Double)
        -> (r: Double, g: Double, b: Double)
    {
        let effectiveRow = Double(y) + (noise - 0.5) * 2.5
        var index = jupiterBandColors.count - 1
        for i in 0..<(jupiterBandStarts.count - 1) {
            if effectiveRow < Double(jupiterBandStarts[i + 1]) {
                index = i
                break
            }
        }
        return jupiterBandColors[index]
    }

    private static func greatRedSpotBlend(
        nx: Double, ny: Double,
        r: Double, g: Double, b: Double
    ) -> (r: Double, g: Double, b: Double) {
        let dx = (nx - 0.60) / 0.13
        let dy = (ny - 0.55) / 0.075
        let dist2 = dx * dx + dy * dy
        guard dist2 < 1.0 else { return (r, g, b) }
        let blend = 1.0 - dist2
        return (
            r * (1.0 - blend) + 0.753 * blend,
            g * (1.0 - blend) + 0.314 * blend,
            b * (1.0 - blend) + 0.227 * blend
        )
    }

    private static func generateJupiterAlbedoMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv
                let edgeNoise = pseudoNoise(x: x, y: y &* 3 &+ 17)
                var (r, g, b) = jupiterBandColor(forRow: y, noise: edgeNoise)
                (r, g, b) = greatRedSpotBlend(nx: nx, ny: ny, r: r, g: g, b: b)
                let limb = limbDarkeningFactor(nx: nx, ny: ny)
                r *= limb; g *= limb; b *= limb
                let bn = (pseudoNoise(x: x, y: y) - 0.5) * 0.14
                r = clamp(r + bn * r); g = clamp(g + bn * g); b = clamp(b + bn * b)
                let i = (y * size + x) * 4
                buf[i] = byte(r); buf[i+1] = byte(g); buf[i+2] = byte(b); buf[i+3] = 255
            }
        }
        return buf
    }

    // MARK: - Saturn  (pale-gold banded disc — body only, rings are geometric in shader)

    private static func createSaturnTexture(diameter: Int) -> CGImage? {
        // Square body-only texture, like other planets.  Rings are rendered
        // geometrically in the Metal fragment shader so we don't bake them here.
        let size = diameter
        let data = generateSaturnMap(size: size)
        guard let base = makeRGBAImage(width: size, height: size, data: data) else { return nil }
        return base
    }

    private static func generateSaturnMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)

        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv

                let (rr, gg, bb) = saturnBodyColor(u: nx * 2 - 1, v: ny * 2 - 1, rBody: 1.0)
                let limb = limbDarkeningFactor(nx: nx, ny: ny)

                let i = (y * size + x) * 4
                buf[i]   = byte(clamp(rr * limb))
                buf[i+1] = byte(clamp(gg * limb))
                buf[i+2] = byte(clamp(bb * limb))
                buf[i+3] = 255
            }
        }
        return buf
    }

    private static func saturnBodyColor(u: Double, v: Double, rBody: Double)
        -> (Double, Double, Double)
    {
        let ny = (v / rBody) * 0.5 + 0.5
        let bandNoise = pseudoNoise(x: Int(u * 100) &* 2, y: Int(v * 100) &* 7 &+ 3)
        let band = 0.5 + 0.5 * sin(ny * Double.pi * 9.0 + bandNoise * 0.8)
        var r = 0.88 + band * 0.08
        var g = 0.76 + band * 0.06
        var b = 0.46 + band * 0.02
        let n = (pseudoNoise(x: Int(u * 1000) &+ 500, y: Int(v * 1000) &+ 300) - 0.5) * 0.06
        r = clamp(r + n); g = clamp(g + n * 0.9); b = clamp(b + n * 0.5)
        let discR = (u * u + v * v).squareRoot()
        let normalised = discR / rBody
        let limb = 1.0 - 0.20 * normalised * normalised
        return (clamp(r * limb), clamp(g * limb), clamp(b * limb))
    }

    // MARK: - Uranus  (pale blue-green ice giant)

    private static func generateUranusAlbedoMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv
                let fy = Double(y) / Double(size)
                // Very subtle banding — Uranus is famously featureless.
                let band = 0.5 + 0.5 * sin(fy * Double.pi * 3.0)
                var r = 0.60 + band * 0.02
                var g = 0.82 + band * 0.03
                var b = 0.84 + band * 0.03
                let n = (pseudoNoise(x: x, y: y) - 0.5) * 0.04
                r = clamp(r + n * 0.5); g = clamp(g + n); b = clamp(b + n)
                let limb = limbDarkeningFactor(nx: nx, ny: ny)
                r = clamp(r * limb); g = clamp(g * limb); b = clamp(b * limb)
                let i = (y * size + x) * 4
                buf[i] = byte(r); buf[i+1] = byte(g); buf[i+2] = byte(b); buf[i+3] = 255
            }
        }
        return buf
    }

    // MARK: - Neptune  (deep blue with faint storm spots)

    private static func generateNeptuneAlbedoMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv
                var r = 0.18 + (pseudoNoise(x: x, y: y) - 0.5) * 0.06
                var g = 0.34 + (pseudoNoise(x: x &+ 50, y: y) - 0.5) * 0.04
                var b = 0.82 + (pseudoNoise(x: x, y: y &+ 50) - 0.5) * 0.06
                // A couple of darker oval storm features (Great Dark Spot homage).
                let storm = pseudoNoise(x: x &* 9 &+ 2, y: y &* 5 &+ 7)
                if storm < 0.07 {
                    let d = (0.07 - storm) / 0.07
                    r -= 0.08 * d; g -= 0.10 * d; b -= 0.14 * d
                }
                let limb = limbDarkeningFactor(nx: nx, ny: ny)
                r = clamp(r * limb); g = clamp(g * limb); b = clamp(b * limb)
                let i = (y * size + x) * 4
                buf[i] = byte(r); buf[i+1] = byte(g); buf[i+2] = byte(b); buf[i+3] = 255
            }
        }
        return buf
    }

    // MARK: - Pluto  (tan/cream with a lighter heart-shaped region)

    private static func generatePlutoAlbedoMap(size: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * inv
                let ny = Double(y) * inv
                // Base brownish-cream.
                var r = 0.72 + (pseudoNoise(x: x, y: y) - 0.5) * 0.10
                var g = 0.60 + (pseudoNoise(x: x &+ 200, y: y) - 0.5) * 0.08
                var b = 0.44 + (pseudoNoise(x: x, y: y &+ 200) - 0.5) * 0.06
                // Tombaugh Regio: a lighter heart-shaped patch roughly centre-left.
                let hx = (nx - 0.38) / 0.22
                let hy = (ny - 0.58) / 0.28
                // Simple parametric heart: |x|^(2/3) + |y| <= 1 approximated.
                let heartDist = pow(abs(hx), 1.4) + abs(hy) - 1.0
                if heartDist < 0.0 {
                    let blend = min(1.0, -heartDist * 3.0)
                    r = r * (1 - blend) + 0.92 * blend
                    g = g * (1 - blend) + 0.86 * blend
                    b = b * (1 - blend) + 0.72 * blend
                }
                let limb = limbDarkeningFactor(nx: nx, ny: ny)
                r = clamp(r * limb); g = clamp(g * limb); b = clamp(b * limb)
                let i = (y * size + x) * 4
                buf[i] = byte(r); buf[i+1] = byte(g); buf[i+2] = byte(b); buf[i+3] = 255
            }
        }
        return buf
    }

    // MARK: - Shared helpers

    private static func limbDarkeningFactor(nx: Double, ny: Double) -> Double {
        let radial = min(1.0, sqrt((nx - 0.5) * (nx - 0.5) + (ny - 0.5) * (ny - 0.5)) / 0.5)
        return 1.0 - 0.18 * (radial * radial)
    }

    private static func makeRGBAImage(width: Int, height: Int, data: [UInt8]) -> CGImage? {
        guard data.count == width * height * 4 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        data.withUnsafeBytes { src in
            if let dest = ctx.data {
                memcpy(dest, src.baseAddress!, data.count)
            }
        }
        return ctx.makeImage()
    }

    // Deterministic hash-based noise, value in [0, 1).
    private static func pseudoNoise(x: Int, y: Int) -> Double {
        let ux = UInt64(bitPattern: Int64(x))
        let uy = UInt64(bitPattern: Int64(y))
        var n = ux &* 73_856_093
        n &+= uy &* 19_349_663
        n &+= 0x9E37_79B9_7F4A_7C15
        n ^= n >> 33
        n &*= 0xff51_afd7_ed55_8ccd
        n ^= n >> 33
        n &*= 0xc4ce_b9fe_1a85_ec53
        n ^= n >> 33
        return Double(n & 0xFFFFFF) / Double(0xFFFFFF)
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0.0), 1.0) }
    private static func byte(_ v: Double) -> UInt8   { UInt8(v * 255.0) }
}
