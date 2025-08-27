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
    public var colorPremul: SIMD4<Float>  // premultiplied RGBA color (r,g,b already multiplied by a)
    public var shape: UInt32              // SpriteShape rawValue
    
    public init(centerPx: SIMD2<Float>, halfSizePx: SIMD2<Float>, colorPremul: SIMD4<Float>, shape: SpriteShape) {
        self.centerPx = centerPx
        self.halfSizePx = halfSizePx
        self.colorPremul = colorPremul
        self.shape = shape.rawValue
    }
}

// Swift-side copy of the uniforms used by SpriteVertex in Shaders.metal
// Must match memory layout exactly.
public struct SpriteUniforms {
    public var viewportSize: SIMD2<Float> // width, height in pixels
    
    public init(viewportSize: SIMD2<Float>) {
        self.viewportSize = viewportSize
    }
}

// Moon parameters per-frame (for renderer logic)
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

// Swift-side copy of the uniforms used by MoonVertex/MoonFragment in Shaders.metal
// Must match memory layout exactly.
public struct MoonUniforms {
    public var viewportSize: SIMD2<Float>     // screen size in pixels
    public var centerPx: SIMD2<Float>         // moon center in pixels
    public var radiusPx: Float                // radius in pixels
    public var phase: Float                   // 0=new, 0.5=full
    public var brightBrightness: Float        // lit multiplier
    public var darkBrightness: Float          // unlit multiplier
    // Note: total floats = 8 (32 bytes). Packing/alignment matches Metal's default (16-byte alignment per vec4).

    public init(viewportSize: SIMD2<Float>,
                centerPx: SIMD2<Float>,
                radiusPx: Float,
                phase: Float,
                brightBrightness: Float,
                darkBrightness: Float) {
        self.viewportSize = viewportSize
        self.centerPx = centerPx
        self.radiusPx = radiusPx
        self.phase = phase
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
    
    public var shootingSprites: [SpriteInstance]      // rendered into shooting-star trail texture
    
    public var moon: MoonParams?                      // draw on top (directly to final drawable)
    public var moonAlbedoImage: CGImage?              // provide when available/changed (optional)
    
    // Debug: show the illuminated region mask (in red) instead of bright texture
    public var showLightAreaTextureFillMask: Bool
    
    public init(size: CGSize,
                clearAll: Bool,
                baseSprites: [SpriteInstance],
                satellitesSprites: [SpriteInstance],
                shootingSprites: [SpriteInstance],
                moon: MoonParams?,
                moonAlbedoImage: CGImage?,
                showLightAreaTextureFillMask: Bool) {
        self.size = size
        self.clearAll = clearAll
        self.baseSprites = baseSprites
        self.satellitesSprites = satellitesSprites
        self.shootingSprites = shootingSprites
        self.moon = moon
        self.moonAlbedoImage = moonAlbedoImage
        self.showLightAreaTextureFillMask = showLightAreaTextureFillMask
    }
}
