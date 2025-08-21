import Foundation
import simd
import CoreGraphics

// Shape types for sprite fragment shader
public enum SpriteShape: UInt32 {
    case rect = 0
    case circle = 1
}

// One instance == one quad on screen with a shape and color
public struct SpriteInstance {
    public var centerPx: SIMD2<Float>     // pixel coordinates
    public var halfSizePx: SIMD2<Float>   // half sizes in pixels (width/2, height/2)
    public var colorPremul: SIMD4<Float>  // premultiplied BGRA color
    public var shape: UInt32              // SpriteShape rawValue
    
    public init(centerPx: SIMD2<Float>, halfSizePx: SIMD2<Float>, colorPremul: SIMD4<Float>, shape: SpriteShape) {
        self.centerPx = centerPx
        self.halfSizePx = halfSizePx
        self.colorPremul = colorPremul
        self.shape = shape.rawValue
    }
}

// Moon parameters per-frame (for GPU shading)
public struct MoonParams {
    public var centerPx: SIMD2<Float>     // pixel center
    public var radiusPx: Float            // pixel radius
    public var phaseFraction: Float       // 0.0=new, 0.5=full, 1.0=new
    public var brightBrightness: Float    // multiplier for lit side
    public var darkBrightness: Float      // multiplier for dark side
    
    public init(centerPx: SIMD2<Float>, radiusPx: Float, phaseFraction: Float, brightBrightness: Float, darkBrightness: Float) {
        self.centerPx = centerPx
        self.radiusPx = radiusPx
        self.phaseFraction = phaseFraction
        self.brightBrightness = brightBrightness
        self.darkBrightness = darkBrightness
    }
}

// Aggregated draw data per frame for the Metal renderer
public struct StarryDrawData {
    public var size: CGSize
    public var clearAll: Bool
    
    public var baseSprites: [SpriteInstance]          // Stars, building lights, flasher circles (persistent base)
    
    public var satellitesSprites: [SpriteInstance]    // rendered into satellites trail texture
    public var satellitesKeepFactor: Float            // 0..1: multiply existing trail by this (0 clears)
    
    public var shootingSprites: [SpriteInstance]      // rendered into shooting-star trail texture
    public var shootingKeepFactor: Float              // 0..1: multiply existing trail by this (0 clears)
    
    public var moon: MoonParams?                      // draw on top (directly to final drawable)
    public var moonAlbedoImage: CGImage?              // provide when available/changed (optional)
    
    public init(size: CGSize,
                clearAll: Bool,
                baseSprites: [SpriteInstance],
                satellitesSprites: [SpriteInstance],
                satellitesKeepFactor: Float,
                shootingSprites: [SpriteInstance],
                shootingKeepFactor: Float,
                moon: MoonParams?,
                moonAlbedoImage: CGImage?) {
        self.size = size
        self.clearAll = clearAll
        self.baseSprites = baseSprites
        self.satellitesSprites = satellitesSprites
        self.satellitesKeepFactor = satellitesKeepFactor
        self.shootingSprites = shootingSprites
        self.shootingKeepFactor = shootingKeepFactor
        self.moon = moon
        self.moonAlbedoImage = moonAlbedoImage
    }
}
