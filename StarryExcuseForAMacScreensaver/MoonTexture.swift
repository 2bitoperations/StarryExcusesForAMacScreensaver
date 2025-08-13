import Foundation
import CoreGraphics

enum MoonTexture {
    static func createMoonTexture(diameter: Int) -> CGImage? {
        let baseSize = 64
        let baseData = generateAlbedoMap(size: baseSize)
        guard let baseImage = makeGrayImage(width: baseSize, height: baseSize, data: baseData) else {
            return nil
        }
        if diameter == baseSize {
            return baseImage
        }
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
    
    private static func generateAlbedoMap(size: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size * size)
        let maria: [(Double, Double, Double, Double)] = [
            (0.38, 0.38, 0.20, 0.55),
            (0.55, 0.42, 0.13, 0.45),
            (0.58, 0.52, 0.11, 0.45),
            (0.32, 0.55, 0.25, 0.50),
            (0.46, 0.58, 0.12, 0.50),
            (0.50, 0.68, 0.14, 0.50),
            (0.40, 0.72, 0.18, 0.55)
        ]
        let invSize = 1.0 / Double(size - 1)
        for y in 0..<size {
            for x in 0..<size {
                let nx = Double(x) * invSize
                let ny = Double(y) * invSize
                let dx = nx - 0.5
                let dy = ny - 0.5
                let r2 = dx*dx + dy*dy
                let radial = min(1.0, sqrt(r2) / 0.5)
                var brightness = 0.88 - 0.10 * radial
                for (mx, my, radius, depth) in maria {
                    let ddx = nx - mx
                    let ddy = ny - my
                    let dist2 = ddx*ddx + ddy*ddy
                    let sigma = radius * 0.5
                    let influence = exp(-dist2 / (2.0 * sigma * sigma))
                    brightness -= depth * 0.5 * influence
                }
                let noise = pseudoNoise(x: x, y: y)
                brightness += (noise - 0.5) * 0.06
                let craterSeed = pseudoNoiseHash(x: x &* 13 &+ y &* 7)
                if craterSeed > 0.995 {
                    brightness += 0.12
                }
                if r2 > 0.25 { brightness = 0.0 }
                brightness = min(max(brightness, 0.05), 1.0)
                let val = 25 + Int(brightness * 215.0)
                buffer[y * size + x] = UInt8(val)
            }
        }
        return buffer
    }
    
    private static func makeGrayImage(width: Int, height: Int, data: [UInt8]) -> CGImage? {
        guard data.count == width * height else { return nil }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        data.withUnsafeBytes { src in
            if let dest = ctx.data {
                memcpy(dest, src.baseAddress!, data.count)
            }
        }
        return ctx.makeImage()
    }
    
    private static func pseudoNoise(x: Int, y: Int) -> Double {
        let ux = UInt64(bitPattern: Int64(x))
        let uy = UInt64(bitPattern: Int64(y))
        var n = ux &* 73856093
        n &+= uy &* 19349663
        n &+= 0x9E3779B97F4A7C15
        n ^= n >> 33; n &*= 0xff51afd7ed558ccd
        n ^= n >> 33; n &*= 0xc4ceb9fe1a85ec53
        n ^= n >> 33
        return Double(n & 0xFFFFFF) / Double(0xFFFFFF)
    }
    
    private static func pseudoNoiseHash(x: Int) -> Double {
        var n = UInt64(bitPattern: Int64(x))
        n &*= 0x9E3779B97F4A7C15
        n ^= n >> 30; n &*= 0xbf58476d1ce4e5b9
        n ^= n >> 27; n &*= 0x94d049bb133111eb
        n ^= n >> 31
        return Double(n & 0xFFFFFF) / Double(0xFFFFFF)
    }
}
