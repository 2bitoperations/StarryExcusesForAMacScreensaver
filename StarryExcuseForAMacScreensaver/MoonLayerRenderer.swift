import CoreGraphics
import Foundation
import QuartzCore
import os

// Moon rendering algorithm (2025, Tier 3 smoothing):
// - High resolution, subpixel motion (pixel snapping removed).
// - Center optionally smoothed with EMA to suppress residual micro stutter after
//   high-resolution progression (tunable alpha).
// - Disk image (shading) still cached; only recomputed when phase / brightness / debug
//   parameters change enough, not for mere positional shifts.
// - Drawing every frame (cheap composite) if the center moves.
//
// NOTE: The disk image is phase-dependent, not position-dependent; we only rebuild when
// fraction changes beyond a threshold or brightness/debug/radius changes.
final class MoonLayerRenderer {
    private let skyline: Skyline
    private let log: OSLog
    private let brightBrightness: CGFloat
    private let darkBrightness: CGFloat
    private let showLightAreaTextureFillMask: Bool

    // Cached shaded disk image & metadata (phase-based)
    private var cachedDiskImage: CGImage?
    private var cachedRadius: CGFloat = -1
    private var cachedPhaseFraction: CGFloat = -1
    private var cachedDebugMode: Bool = false
    private var cachedBright: CGFloat = -1
    private var cachedDark: CGFloat = -1
    private var lastShadingRenderTime: CFTimeInterval = 0

    // Smoothed center (EMA)
    private var filteredCenter: CGPoint?
    private let smoothingAlpha: CGFloat = 0.30  // higher -> tracks target faster

    // Instrumentation
    private var frameIndex: UInt64 = 0

    init(
        skyline: Skyline,
        log: OSLog,
        brightBrightness: CGFloat,
        darkBrightness: CGFloat,
        showLightAreaTextureFillMask: Bool
    ) {
        self.skyline = skyline
        self.log = log
        self.brightBrightness = brightBrightness
        self.darkBrightness = darkBrightness
        self.showLightAreaTextureFillMask = showLightAreaTextureFillMask
    }

    // Returns true if the moon disk image was regenerated (not merely repositioned).
    func renderMoon(into context: CGContext) -> Bool {
        frameIndex &+= 1
        let logThis = (frameIndex <= 5) || (frameIndex % 120 == 0)

        guard let moon = skyline.getMoon() else {
            if logThis {
                os_log(
                    "MoonLayerRenderer: no Moon available",
                    log: log,
                    type: .debug
                )
            }
            return false
        }
        guard let texture = moon.textureImage else {
            if logThis {
                os_log(
                    "MoonLayerRenderer: Moon has no textureImage",
                    log: log,
                    type: .debug
                )
            }
            return false
        }

        // High-resolution (subpixel) target center
        let targetCenter = moon.currentCenter()

        // Exponential smoothing to reduce micro jitter without introducing large lag.
        if let prev = filteredCenter {
            let nx = prev.x + smoothingAlpha * (targetCenter.x - prev.x)
            let ny = prev.y + smoothingAlpha * (targetCenter.y - prev.y)
            filteredCenter = CGPoint(x: nx, y: ny)
        } else {
            filteredCenter = targetCenter
        }
        guard let center = filteredCenter else { return false }

        let r = CGFloat(moon.radius)

        // Dynamic illuminated fraction
        let fRaw = moon.illuminatedFraction
        let f = CGFloat(min(max(fRaw, 0.0), 1.0))

        // Decide if we need to regenerate shaded disk (phase-based)
        let now = CACurrentMediaTime()
        let synodicSec = Moon.synodicMonthDays * 86400.0
        let timePerPixel = (r > 0) ? synodicSec / (4.0 * Double(r)) : 0
        let dt = now - lastShadingRenderTime

        // Fractional change threshold; increase a bit because phase now updates smoothly each frame.
        let fracPerPixel = (r > 0) ? (1.0 / (4.0 * r)) : 1.0
        let fractionDeltaThreshold = max(fracPerPixel / 4.0, 0.0010)
        let fractionDelta = abs(f - cachedPhaseFraction)

        var needsRegenerate = false
        if cachedDiskImage == nil { needsRegenerate = true }
        if cachedRadius != r { needsRegenerate = true }
        if cachedDebugMode != showLightAreaTextureFillMask {
            needsRegenerate = true
        }
        if cachedBright != brightBrightness || cachedDark != darkBrightness {
            needsRegenerate = true
        }
        if fractionDelta >= fractionDeltaThreshold { needsRegenerate = true }
        if dt >= timePerPixel { needsRegenerate = true }

        if needsRegenerate {
            if logThis {
                os_log(
                    "MoonLayerRenderer: regenerate disk r=%.1f illum=%.4f Δ=%.4f bright=%.2f dark=%.2f dbg=%@",
                    log: log,
                    type: .info,
                    Double(r),
                    Double(f),
                    Double(fractionDelta),
                    Double(brightBrightness),
                    Double(darkBrightness),
                    showLightAreaTextureFillMask ? "on" : "off"
                )
            }
            cachedDiskImage = buildShadedDiskImage(
                texture: texture,
                radius: r,
                fraction: f
            )
            cachedRadius = r
            cachedPhaseFraction = f
            cachedDebugMode = showLightAreaTextureFillMask
            cachedBright = brightBrightness
            cachedDark = darkBrightness
            lastShadingRenderTime = now
        } else if logThis {
            os_log(
                "MoonLayerRenderer: reuse cached disk (phase stable)",
                log: log,
                type: .debug
            )
        }

        guard let diskImage = cachedDiskImage else {
            if logThis {
                os_log(
                    "MoonLayerRenderer: cachedDiskImage nil after generation",
                    log: log,
                    type: .error
                )
            }
            return false
        }

        // Composite the (phase) disk at new center every frame (cheap).
        let fullRect = CGRect(
            x: 0,
            y: 0,
            width: context.width,
            height: context.height
        )
        context.clear(fullRect)
        let moonRect = CGRect(
            x: center.x - r,
            y: center.y - r,
            width: 2 * r,
            height: 2 * r
        )
        context.saveGState()
        context.interpolationQuality = .low  // allow mild filtering to reduce sparkle
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.draw(diskImage, in: moonRect)
        context.restoreGState()

        return needsRegenerate
    }

    // Builds (or rebuilds) the shaded disk CGImage (size 2r x 2r) at origin.
    private func buildShadedDiskImage(
        texture: CGImage,
        radius r: CGFloat,
        fraction f: CGFloat
    ) -> CGImage? {
        if r <= 0 {
            os_log(
                "MoonLayerRenderer: invalid radius %.3f",
                log: log,
                type: .error,
                Double(r)
            )
            return nil
        }
        let size = Int(ceil(2 * r))
        guard size > 0 else {
            os_log(
                "MoonLayerRenderer: invalid size %d",
                log: log,
                type: .error,
                size
            )
            return nil
        }

        guard
            let diskCtx = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            os_log(
                "MoonLayerRenderer: failed to create disk context",
                log: log,
                type: .error
            )
            return nil
        }
        diskCtx.interpolationQuality = .none  // texture copied raw here; outer composite may smooth
        diskCtx.setShouldAntialias(true)
        diskCtx.setAllowsAntialiasing(true)

        let moonRect = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        let waxing = skyline.getMoon()?.waxing ?? true

        let newThreshold: CGFloat = 0.0005
        let fullThreshold: CGFloat = 0.9995

        // DEBUG MODE: Only show illuminated region mask (no dark base)
        if showLightAreaTextureFillMask {
            if f <= newThreshold {
                return diskCtx.makeImage()
            }
            if f >= fullThreshold {
                diskCtx.addEllipse(in: moonRect)
                diskCtx.setFillColor(
                    CGColor(red: 1, green: 0, blue: 0, alpha: 0.9)
                )
                diskCtx.fillPath()
                return diskCtx.makeImage()
            }
            if let maskImage = buildIlluminatedMask(
                radius: r,
                fraction: f,
                waxing: waxing
            ) {
                diskCtx.saveGState()
                diskCtx.clip(to: moonRect, mask: maskImage)
                diskCtx.setFillColor(
                    CGColor(red: 1, green: 0, blue: 0, alpha: 0.9)
                )
                diskCtx.fill(moonRect)
                diskCtx.restoreGState()
            }
            return diskCtx.makeImage()
        }

        // Normal mode: dark disk then bright region overlay
        drawTexture(
            context: diskCtx,
            image: texture,
            in: moonRect,
            brightness: darkBrightness,
            clipToCircle: true
        )

        if f <= newThreshold {
            return diskCtx.makeImage()
        }
        if f >= fullThreshold {
            diskCtx.saveGState()
            diskCtx.addEllipse(in: moonRect)
            diskCtx.clip()
            drawTexture(
                context: diskCtx,
                image: texture,
                in: moonRect,
                brightness: brightBrightness,
                clipToCircle: false
            )
            diskCtx.restoreGState()
            return diskCtx.makeImage()
        }

        if let maskImage = buildIlluminatedMask(
            radius: r,
            fraction: f,
            waxing: waxing
        ) {
            diskCtx.saveGState()
            diskCtx.clip(to: moonRect, mask: maskImage)
            drawTexture(
                context: diskCtx,
                image: texture,
                in: moonRect,
                brightness: brightBrightness,
                clipToCircle: false
            )
            diskCtx.restoreGState()
        }

        return diskCtx.makeImage()
    }

    // MARK: - Mask Construction (legacy crescent logic retained; could be replaced by analytic terminator)

    private func buildIlluminatedMask(
        radius r: CGFloat,
        fraction f: CGFloat,
        waxing: Bool
    ) -> CGImage? {
        let size = Int(ceil(2 * r))
        if size <= 0 { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard
            let maskCtx = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: 0
            )
        else { return nil }

        maskCtx.setAllowsAntialiasing(true)
        maskCtx.setShouldAntialias(true)

        maskCtx.setFillColor(gray: 0, alpha: 1)
        maskCtx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let moonRect = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)

        if f <= 0.5 {
            drawCrescentMask(
                into: maskCtx,
                moonRect: moonRect,
                fraction: f,
                waxing: waxing,
                fillWhite: true,
                subtractMode: false
            )
        } else {
            maskCtx.setFillColor(gray: 1, alpha: 1)
            maskCtx.addEllipse(in: moonRect)
            maskCtx.fillPath()
            let darkFraction = 1.0 - f
            if darkFraction > 0 {
                drawCrescentMask(
                    into: maskCtx,
                    moonRect: moonRect,
                    fraction: darkFraction,
                    waxing: !waxing,
                    fillWhite: false,
                    subtractMode: true
                )
            }
        }

        if let dataPtr = maskCtx.data {
            sanitizeMaskEdge(
                data: dataPtr,
                width: size,
                height: size,
                bytesPerRow: maskCtx.bytesPerRow,
                radius: r
            )
        }

        return maskCtx.makeImage()
    }

    private func sanitizeMaskEdge(
        data: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        radius r: CGFloat
    ) {
        let edgeBand = max(2.0, min(6.0, r * 0.06))
        let rSq = r * r
        let innerBandRadius = r - edgeBand
        let innerBandRadiusSq = innerBandRadius * innerBandRadius

        let rowBytes = bytesPerRow
        for y in 0..<height {
            let rowPtr = data.advanced(by: y * rowBytes)
            for x in 0..<width {
                let p = rowPtr.advanced(by: x)
                let val = p.load(as: UInt8.self)

                let fx = CGFloat(x) + 0.5 - r
                let fy = CGFloat(y) + 0.5 - r
                let dSq = fx * fx + fy * fy

                if dSq >= rSq {
                    if val != 0 { p.storeBytes(of: UInt8(0), as: UInt8.self) }
                    continue
                }

                if dSq >= innerBandRadiusSq {
                    if val >= 128 {
                        if val != 255 {
                            p.storeBytes(of: UInt8(255), as: UInt8.self)
                        }
                    } else {
                        if val != 0 {
                            p.storeBytes(of: UInt8(0), as: UInt8.self)
                        }
                    }
                } else {
                    if val > 0 && val < 4 {
                        p.storeBytes(of: UInt8(0), as: UInt8.self)
                    } else if val > 252 && val < 255 {
                        p.storeBytes(of: UInt8(255), as: UInt8.self)
                    }
                }
            }
        }
    }

    private func drawCrescentMask(
        into ctx: CGContext,
        moonRect: CGRect,
        fraction f: CGFloat,
        waxing: Bool,
        fillWhite: Bool,
        subtractMode: Bool
    ) {
        let r = moonRect.width / 2.0
        let center = CGPoint(x: moonRect.midX, y: moonRect.midY)
        let (ellipseRect, rightSideRect, leftSideRect, _, _) =
            phaseGeometry(radius: r, center: center, fraction: f)

        let sideRect = waxing ? rightSideRect : leftSideRect

        ctx.saveGState()
        ctx.clip(to: sideRect)

        let path = CGMutablePath()
        path.addEllipse(in: moonRect)
        path.addEllipse(in: ellipseRect)
        ctx.addPath(path)

        ctx.setFillColor(gray: subtractMode ? 0 : (fillWhite ? 1 : 0), alpha: 1)
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
    }

    private func phaseGeometry(
        radius r: CGFloat,
        center: CGPoint,
        fraction f: CGFloat
    ) -> (CGRect, CGRect, CGRect, CGFloat, CGFloat) {
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let rawEllipseWidth = 2.0 * r * minorScale
        let ellipseWidth = max(0.5, rawEllipseWidth)
        let ellipseRect = CGRect(
            x: center.x - ellipseWidth / 2.0,
            y: center.y - r,
            width: ellipseWidth,
            height: 2 * r
        )
        let moonRect = CGRect(
            x: center.x - r,
            y: center.y - r,
            width: 2 * r,
            height: 2 * r
        )
        let overlap: CGFloat = 1.0
        let centerX = moonRect.midX
        let rightSideRect = CGRect(
            x: centerX - overlap,
            y: moonRect.minY,
            width: r + overlap,
            height: moonRect.height
        )
        let leftSideRect = CGRect(
            x: centerX - r,
            y: moonRect.minY,
            width: r + overlap,
            height: moonRect.height
        )
        return (
            ellipseRect, rightSideRect, leftSideRect, cosTheta, ellipseWidth
        )
    }

    private func drawTexture(
        context: CGContext,
        image: CGImage,
        in rect: CGRect,
        brightness: CGFloat,
        clipToCircle: Bool
    ) {
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

extension CGRect {
    fileprivate var maxX: CGFloat { origin.x + size.width }
}
