import Foundation
import CoreGraphics
import os

// Moon rendering algorithm (2025):
// 1. Always draw FULL dark textured disk (no dark-side extension).
// 2. Compute illuminated region mask for the current phase.
// 3. Draw bright texture EXACTLY ONCE clipped by that mask (or fill red in debug mode).
// Improvement (halo suppression):
//    The earlier mask implementation could leave a faint low‑alpha ring
//    along the dark circumference due to anti‑aliasing of the crescent
//    construction (especially after subtracting the dark crescent in
//    gibbous phases). We now post-process the mask to:
//      - Eliminate any near‑zero incidental alpha outside the intended
//        illuminated region.
//      - Force edge pixels within a narrow outer band (r - ~1px .. r)
//        to be strictly 0 or 255 so the dark rim stays fully dark.
//      - Preserve the smooth anti‑aliased gradient ONLY along the
//        interior terminator (not on the outer circumference).
//
// No subsequent dark-over-bright passes. Extension/oversize options are ignored.
final class MoonLayerRenderer {
    private let skyline: Skyline
    private let log: OSLog
    private let brightBrightness: CGFloat
    private let darkBrightness: CGFloat
    private let showLightAreaTextureFillMask: Bool
    
    // internal reuse / debug
    private var frameCounter: Int = 0
    private let debugMoon = false
    private let debugMoonLogEveryNFrames = 60
    
    init(skyline: Skyline,
         log: OSLog,
         brightBrightness: CGFloat,
         darkBrightness: CGFloat,
         showLightAreaTextureFillMask: Bool) {
        self.skyline = skyline
        self.log = log
        self.brightBrightness = brightBrightness
        self.darkBrightness = darkBrightness
        self.showLightAreaTextureFillMask = showLightAreaTextureFillMask
    }
    
    @inline(__always)
    private func pixelAlign(_ value: CGFloat) -> CGFloat { round(value) }
    
    func renderMoon(into context: CGContext) {
        frameCounter &+= 1
        guard let moon = skyline.getMoon(),
              let texture = moon.textureImage else { return }
        
        let rawCenter = moon.currentCenter()
        let r = CGFloat(moon.radius)
        let center = CGPoint(x: pixelAlign(rawCenter.x), y: pixelAlign(rawCenter.y))
        let fRaw = moon.illuminatedFraction
        let f = CGFloat(min(max(fRaw, 0.0), 1.0))
        let waxing = moon.waxing
        
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .none
        
        // 1. Full dark disk
        drawTexture(context: context,
                    image: texture,
                    in: moonRect,
                    brightness: darkBrightness,
                    clipToCircle: true)
        
        // 2. Illuminated region (mask)
        let newThreshold: CGFloat = 0.0005
        let fullThreshold: CGFloat = 0.9995
        
        if f <= newThreshold {
            // No illuminated region
            context.restoreGState()
            return
        }
        
        if f >= fullThreshold {
            // Full bright disk
            context.saveGState()
            context.addEllipse(in: moonRect)
            context.clip()
            drawBrightOrMask(context: context, texture: texture, in: moonRect)
            context.restoreGState()
            context.restoreGState()
            return
        }
        
        // Intermediate phase: build mask via offscreen alpha context
        if let maskImage = buildIlluminatedMask(radius: r,
                                                fraction: f,
                                                waxing: waxing) {
            context.saveGState()
            context.clip(to: moonRect, mask: maskImage)
            drawBrightOrMask(context: context, texture: texture, in: moonRect)
            context.restoreGState()
        }
        
        context.restoreGState()
    }
    
    // MARK: - Mask Construction
    
    private func buildIlluminatedMask(radius r: CGFloat,
                                      fraction f: CGFloat,
                                      waxing: Bool) -> CGImage? {
        let size = Int(ceil(2*r))
        if size <= 0 { return nil }
        
        // Grayscale 8-bit mask context
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = 0
        guard let maskCtx = CGContext(data: nil,
                                      width: size,
                                      height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: 0)
        else { return nil }
        
        // We WANT anti-aliasing for a smooth terminator, but any artifacts
        // at the outer circumference will be binary-cleaned later.
        maskCtx.setAllowsAntialiasing(true)
        maskCtx.setShouldAntialias(true)
        
        // Start fully black (no illumination).
        maskCtx.setFillColor(gray: 0, alpha: 1)
        maskCtx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        
        let moonRect = CGRect(x: 0, y: 0, width: 2*r, height: 2*r)
        
        if f <= 0.5 {
            // Bright minority crescent
            drawCrescentMask(into: maskCtx,
                             moonRect: moonRect,
                             fraction: f,
                             waxing: waxing,
                             fillWhite: true,
                             subtractMode: false)
        } else {
            // Bright majority (gibbous): fill full disk then subtract dark crescent
            maskCtx.setFillColor(gray: 1, alpha: 1)
            maskCtx.addEllipse(in: moonRect)
            maskCtx.fillPath()
            
            let darkFraction = 1.0 - f
            if darkFraction > 0 {
                drawCrescentMask(into: maskCtx,
                                 moonRect: moonRect,
                                 fraction: darkFraction,
                                 waxing: !waxing, // dark crescent opposite side
                                 fillWhite: false,
                                 subtractMode: true)
            }
        }
        
        // Post-process to eliminate faint halo around dark circumference.
        if let dataPtr = maskCtx.data {
            sanitizeMaskEdge(data: dataPtr,
                             width: size,
                             height: size,
                             bytesPerRow: maskCtx.bytesPerRow,
                             radius: r)
        }
        
        return maskCtx.makeImage()
    }
    
    // Eliminate faint non-zero alpha along *dark* circumference while preserving
    // the anti-aliased gradient of the terminator inside the moon.
    //
    // Strategy:
    //   - Identify an outer edge band (last ~1px toward radius).
    //   - Inside that band force pixel either 0 or 255 (no low-alpha).
    //   - Elsewhere:
    //       * Snap very small values (<2) to 0.
    //       * Snap almost pure white (>253) to 255 (stabilizes mask).
    // This keeps smooth gradient mid-range values only along the
    // interior terminator (which is well away from the outer rim).
    private func sanitizeMaskEdge(data: UnsafeMutableRawPointer,
                                  width: Int,
                                  height: Int,
                                  bytesPerRow: Int,
                                  radius r: CGFloat) {
        let edgeBand: CGFloat = 1.15   // width in pixels near outer rim to force hard 0/255
        let rSq = r * r
        let innerBandRadius = r - edgeBand
        let innerBandRadiusSq = innerBandRadius * innerBandRadius
        
        let rowBytes = bytesPerRow
        for y in 0..<height {
            let rowPtr = data.advanced(by: y * rowBytes)
            for x in 0..<width {
                let p = rowPtr.advanced(by: x)
                let val = p.load(as: UInt8.self)
                
                // Center relative coords (sample at pixel center)
                let fx = CGFloat(x) + 0.5 - r
                let fy = CGFloat(y) + 0.5 - r
                let dSq = fx*fx + fy*fy
                
                if dSq >= rSq {
                    // Outside nominal circle (should already be 0, but enforce)
                    if val != 0 { p.storeBytes(of: UInt8(0), as: UInt8.self) }
                    continue
                }
                
                if dSq >= innerBandRadiusSq {
                    // In edge band: force binary to avoid halo
                    // Consider anything >= ~200 as illuminated; else dark.
                    if val >= 200 {
                        if val != 255 { p.storeBytes(of: UInt8(255), as: UInt8.self) }
                    } else {
                        if val != 0 { p.storeBytes(of: UInt8(0), as: UInt8.self) }
                    }
                } else {
                    // Interior region:
                    // Flatten minuscule noise & near-white extremes for stability
                    if val > 0 && val < 2 {
                        p.storeBytes(of: UInt8(0), as: UInt8.self)
                    } else if val > 253 && val < 255 {
                        p.storeBytes(of: UInt8(255), as: UInt8.self)
                    }
                }
            }
        }
    }
    
    // Draw (or subtract) a crescent shape into the mask context.
    // fraction represents the minority fraction (0 < fraction <= 0.5).
    // If subtractMode == false and fillWhite==true -> fill crescent white onto black.
    // If subtractMode == true -> fill crescent black over existing white (subtract).
    private func drawCrescentMask(into ctx: CGContext,
                                  moonRect: CGRect,
                                  fraction f: CGFloat,
                                  waxing: Bool,
                                  fillWhite: Bool,
                                  subtractMode: Bool) {
        let r = moonRect.width / 2.0
        let center = CGPoint(x: moonRect.midX, y: moonRect.midY)
        let (ellipseRect, rightSideRect, leftSideRect, _, _) =
            phaseGeometry(radius: r, center: center, fraction: f)
        
        let sideRect = waxing ? rightSideRect : leftSideRect
        
        ctx.saveGState()
        ctx.clip(to: sideRect)
        
        // Path for crescent region: (moon circle) - (terminator ellipse) inside side half-plane
        let path = CGMutablePath()
        path.addEllipse(in: moonRect)
        path.addEllipse(in: ellipseRect)
        ctx.addPath(path)
        
        ctx.setFillColor(gray: subtractMode ? 0 : (fillWhite ? 1 : 0), alpha: 1)
        ctx.drawPath(using: .eoFill) // even-odd yields ring-like crescent
        ctx.restoreGState()
    }
    
    // MARK: - Phase Geometry (reused logic)
    
    private func phaseGeometry(radius r: CGFloat,
                               center: CGPoint,
                               fraction f: CGFloat) -> (CGRect, CGRect, CGRect, CGFloat, CGFloat) {
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(0.5, rawEllipseWidth)
        let ellipseRect = CGRect(x: center.x - ellipseWidth / 2.0,
                                 y: center.y - r,
                                 width: ellipseWidth,
                                 height: 2 * r)
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        // Side rectangles (used to isolate one half-plane)
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        let rightSideRect = CGRect(x: centerX - overlap,
                                   y: moonRect.minY,
                                   width: r + overlap,
                                   height: moonRect.height)
        let leftSideRect = CGRect(x: centerX - r,
                                  y: moonRect.minY,
                                  width: r + overlap,
                                  height: moonRect.height)
        return (ellipseRect, rightSideRect, leftSideRect, cosTheta, ellipseWidth)
    }
    
    // MARK: - Bright Draw (or Debug Mask)
    
    private func drawBrightOrMask(context: CGContext,
                                  texture: CGImage,
                                  in rect: CGRect) {
        if showLightAreaTextureFillMask {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
            context.fill(rect)
        } else {
            drawTexture(context: context,
                        image: texture,
                        in: rect,
                        brightness: brightBrightness,
                        clipToCircle: false)
        }
    }
    
    // MARK: - Texture Drawing
    
    private func drawTexture(context: CGContext,
                             image: CGImage,
                             in rect: CGRect,
                             brightness: CGFloat,
                             clipToCircle: Bool) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        if clipToCircle {
            context.addEllipse(in: rect)
            context.clip()
        }
        context.draw(image, in: rect)
        if brightness < 0.999 {
            let alpha = min(1.0, max(0.0, 1.0 - brightness))
            if alpha > 0 {
                context.setFillColor(CGColor(gray: 0.0, alpha: alpha))
                context.fill(rect)
            }
        }
        context.restoreGState()
    }
}

private extension CGRect {
    var maxX: CGFloat { origin.x + size.width }
}
