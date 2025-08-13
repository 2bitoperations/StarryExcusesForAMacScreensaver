import Foundation
import CoreGraphics

// Procedurally generates a low-resolution grayscale "lunar" texture.
// Base resolution 64x64 for improved detail while retaining a retro pixel look
// (scaled with nearest-neighbor).
//
// Approximates major near-side maria using Gaussian dark basins plus mild
// deterministic noise and sparse crater rim brightenings. Fully deterministic
// (no random()) so appearance is stable across runs.
enum MoonTexture {
    
    // Public entry: create (or scale) a lunar texture for a given diameter.
    // The base procedural map is 64x64; larger diameters are scaled up with
    // nearest-neighbor; smaller diameters are scaled down (still nearest).
    static func createMoonTexture(diameter: Int) -> CGImage? {
        let baseSize = 64
        let baseData = generateAlbedoMap(size: baseSize)
        guard let baseImage = makeGrayImage(width: baseSize,
                                            height: baseSize,
                                            data: baseData) else {
            return nil
        }
        if diameter == baseSize {
            return baseImage
        }
        // Scale using nearest neighbor.
        guard let scaledCtx = CGContext(data: nil,
                                        width: diameter,
                                        height: diameter,
                                        bitsPerComponent: 8,
                                        bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return baseImage
        }
        scaledCtx.interpolationQuality = .none
        scaledCtx.draw(baseImage, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        return scaledCtx.makeImage()
    }
    
    // MARK: - Core Generation
    
    // Generate an albedo (brightness) map in [0,255] for a square texture.
    // Brightness modeling:
    //   - Base highland brightness ~0.82 - 0.90 with slight radial limb darkening.
    //   - Subtract Gaussian basins for maria (darker seas).
    //   - Add subtle deterministic noise & crater highlights.
    private static func generateAlbedoMap(size: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size * size)
        
        // Major maria approximate positions (normalized 0..1):
        // (x, y, radius, depth)
        let maria: [(Double, Double, Double, Double)] = [
            (0.38, 0.38, 0.20, 0.55), // Mare Imbrium
            (0.55, 0.42, 0.13, 0.45), // Mare Serenitatis
            (0.58, 0.52, 0.11, 0.45), // Mare Tranquillitatis
            (0.32, 0.55, 0.25, 0.50), // Oceanus Procellarum (portion)
            (0.46, 0.58, 0.12, 0.50), // Mare Nubium
            (0.50, 0.68, 0.14, 0.50), // Mare Nectaris (approx)
            (0.40, 0.72, 0.18, 0.55)  // Mare Humorum (approx)
        ]
        
        let invSize = 1.0 / Double(size - 1)
        
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * invSize
                let ny = Double(y) * invSize
                
                // Radial distance from center for limb darkening.
                let dx = nx - 0.5
                let dy = ny - 0.5
                let r2 = dx*dx + dy*dy
                
                // Base highland brightness + mild limb falloff.
                let radial = min(1.0, sqrt(r2) / 0.5)
                var brightness = 0.88 - 0.10 * radial
                
                // Maria Gaussian darkening.
                for (mx, my, radius, depth) in maria {
                    let ddx = nx - mx
                    let ddy = ny - my
                    let dist2 = ddx*ddx + ddy*ddy
                    let sigma = radius * 0.5 // radius ~ 2σ
                    let influence = exp(-dist2 / (2.0 * sigma * sigma))
                    brightness -= depth * 0.5 * influence
                }
                
                // Deterministic pseudo-noise
                let noise = pseudoNoise(x: x, y: y)
                brightness += (noise - 0.5) * 0.06
                
                // Sparse crater rim brightenings
                let craterSeed = pseudoNoiseHash(x: x &* 13 &+ y &* 7)
                if craterSeed > 0.995 {
                    // Simple boost (no ring shape complexity to keep cost low)
                    brightness += 0.12
                }
                
                // Outside disc: zero (will be clipped by circular mask when drawn).
                if r2 > 0.25 {
                    brightness = 0.0
                }
                
                brightness = min(max(brightness, 0.05), 1.0)
                
                // Map to 8-bit grayscale (avoid extremes: 25..240)
                let val = 25 + Int(brightness * 215.0)
                buffer[y * size + x] = UInt8(val)
            }
        }
        
        return buffer
    }
    
    // Create a grayscale CGImage from raw 8-bit data.
    // Copies data into a CGContext-owned buffer to avoid dangling pointer issues.
    private static func makeGrayImage(width: Int, height: Int, data: [UInt8]) -> CGImage? {
        guard data.count == width * height else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        // Copy bytes into context-managed memory
        data.withUnsafeBytes { src in
            if let dest = ctx.data {
                memcpy(dest, src.baseAddress!, data.count)
            }
        }
        return ctx.makeImage()
    }
    
    // Simple deterministic pseudo-noise (0..1) from integer coords using bit mixing.
    private static func pseudoNoise(x: Int, y: Int) -> Double {
        // Promote to UInt64 for mixing; avoid signed overflow.
        let ux = UInt64(bitPattern: Int64(x))
        let uy = UInt64(bitPattern: Int64(y))
        var n = ux &* 73856093
        n &+= uy &* 19349663
        n &+= 0x9E3779B97F4A7C15 // large odd constant (golden ratio basis)
        // xorshift+mix steps
        n ^= n >> 33; n &*= 0xff51afd7ed558ccd
        n ^= n >> 33; n &*= 0xc4ceb9fe1a85ec53
        n ^= n >> 33
        let v = Double(n & 0xFFFFFF) / Double(0xFFFFFF)
        return v
    }
    
    // Variant hash returning 0..1
    private static func pseudoNoiseHash(x: Int) -> Double {
        var n = UInt64(bitPattern: Int64(x))
        n &*= 0x9E3779B97F4A7C15
        n ^= n >> 30; n &*= 0xbf58476d1ce4e5b9
        n ^= n >> 27; n &*= 0x94d049bb133111eb
        n ^= n >> 31
        return Double(n & 0xFFFFFF) / Double(0xFFFFFF)
    }
}
