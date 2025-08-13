import Foundation
import CoreGraphics

// Generates a low-resolution grayscale "lunar" texture intended to be scaled
// up with nearest-neighbor interpolation for a retro pixel look. The pattern
// uses a 32x32 brightness map approximating maria / highlands contrast.
enum MoonTexture {
    
    // 32x32 brightness pattern encoded as characters '0'..'9' (darker->lighter)
    // Crafted to give a few blotchy darker maria-like regions.
    private static let pattern: [String] = [
        "77888999999998888888888899998877",
        "77888999999998888888888899998877",
        "66888899999988888888889999998866",
        "55888888999998888889999988888855",
        "55888888888888888888888888888855",
        "55888888777777888877777788888855",
        "55888888766666788876666688888855",
        "558888877666667887666667788888855",
        "558888776666666666666666777888855",
        "558888776555555666555555777888855",
        "668888776555555665555555777888866",
        "668888776555555665555555777888866",
        "668888776555555665555555777888866",
        "668888776555555665555555777888866",
        "668888776655556665555567777888866",
        "668888776655556665555567777888866",
        "668888777655556665555567777888866",
        "668888777665556666555667777888866",
        "668888777766666666666667777888866",
        "668888777776666666666667777888866",
        "668888777777777777777777777888866",
        "668888777777777777777777777888866",
        "668888888777777777777777888888866",
        "778888888888888888888888888888877",
        "778888888888888888888888888888877",
        "778888888888888888888888888888877",
        "778888888888888888888888888888877",
        "778888888888888888888888888888877",
        "778888999888888888888888899888877",
        "778889999888888888888888899998877",
        "778889999988888888888888999998877",
        "778889999999888888888889999998877"
    ]
    
    // Convert the pattern to raw 8-bit grayscale data.
    private static func makeBaseData() -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(32*32)
        for row in pattern {
            let chars = Array(row)
            for c in chars {
                if let val = c.wholeNumberValue {
                    // Map 0..9 -> 60..255 brightness (avoid absolute black)
                    let brightness = 60 + Int(Double(val)/9.0 * 195.0)
                    data.append(UInt8(brightness))
                } else {
                    data.append(128)
                }
            }
        }
        return data
    }
    
    // Create a CGImage with the texture scaled to given diameter (nearest neighbor).
    static func createMoonTexture(diameter: Int) -> CGImage? {
        let baseSize = 32
        let data = makeBaseData()
        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let baseCtx = CGContext(data: UnsafeMutableRawPointer(mutating: data),
                                      width: baseSize,
                                      height: baseSize,
                                      bitsPerComponent: 8,
                                      bytesPerRow: baseSize,
                                      space: graySpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        guard let baseImage = baseCtx.makeImage() else { return nil }
        
        // If diameter <= baseSize, return base (it will be scaled down when drawn).
        if diameter == baseSize {
            return baseImage
        }
        
        // Scale with nearest-neighbor
        guard let scaledCtx = CGContext(data: nil,
                                        width: diameter,
                                        height: diameter,
                                        bitsPerComponent: 8,
                                        bytesPerRow: 0,
                                        space: graySpace,
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return baseImage
        }
        scaledCtx.interpolationQuality = .none
        let destRect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        scaledCtx.draw(baseImage, in: destRect)
        return scaledCtx.makeImage()
    }
}
