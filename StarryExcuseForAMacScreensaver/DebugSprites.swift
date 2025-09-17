import Foundation
import CoreGraphics
import simd

// Helper for constructing debug outline rectangle sprites (shape = .rectOutline).
// Expects premultiplied RGBA color (rgb already multiplied by alpha).
// Returns nil if rect is empty or has non-finite values.
func makeRectOutlineSprite(rect: CGRect,
                           colorPremul: SIMD4<Float>) -> SpriteInstance? {
    guard rect.width > 0,
          rect.height > 0,
          rect.isFinite else { return nil }
    
    let cx = Float(rect.midX)
    let cy = Float(rect.midY)
    let halfW = Float(rect.width * 0.5)
    let halfH = Float(rect.height * 0.5)
    
    return SpriteInstance(centerPx: SIMD2<Float>(cx, cy),
                          halfSizePx: SIMD2<Float>(halfW, halfH),
                          colorPremul: colorPremul,
                          shape: .rectOutline)
}

private extension CGRect {
    var isFinite: Bool {
        return x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}
