import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import os

/// Handles creation, updating, and drawing of the debug text overlay (FPS / CPU, etc.)
final class DebugLayerRenderer {

    private let device: MTLDevice
    private let log: OSLog

    // Overlay state
    private var overlayTexture: MTLTexture?
    private var overlayQuadVertexBuffer: MTLBuffer?
    private var lastOverlayString: String = ""
    private var lastOverlayUpdateTime: CFTimeInterval = 0
    private var overlayWidthPx: Int = 0
    private var overlayHeightPx: Int = 0
    private let overlayUpdateInterval: CFTimeInterval = 0.25  // seconds
    private var lastOverlayDrawnFrame: UInt64 = 0
    private var lastOverlayLogTime: CFTimeInterval = 0

    // Build info overlay state (static text, rendered once)
    private var buildInfoTexture: MTLTexture?
    private var buildInfoQuadVertexBuffer: MTLBuffer?
    private var buildInfoWidthPx: Int = 0
    private var buildInfoHeightPx: Int = 0
    private var buildInfoRendered: Bool = false
    private var buildInfoLastScreenSize: CGSize = .zero

    init(device: MTLDevice, log: OSLog) {
        self.device = device
        self.log = log
    }

    var hasOverlayTexture: Bool { overlayTexture != nil }

    func approxTextureBytes() -> Int {
        var total = 0
        if let tex = overlayTexture { total += tex.width * tex.height * 4 }
        if let tex = buildInfoTexture { total += tex.width * tex.height * 4 }
        return total
    }

    func releaseResources() {
        overlayTexture = nil
        overlayQuadVertexBuffer = nil
        lastOverlayString = ""
        overlayWidthPx = 0
        overlayHeightPx = 0
        lastOverlayDrawnFrame = 0
        buildInfoTexture = nil
        buildInfoQuadVertexBuffer = nil
        buildInfoRendered = false
        buildInfoWidthPx = 0
        buildInfoHeightPx = 0
        buildInfoLastScreenSize = .zero
    }

    func update(drawData: StarryDrawData, effectiveEnabled: Bool) {
        guard effectiveEnabled else { return }

        let now = CACurrentMediaTime()
        let fps = drawData.debugFPS
        let cpu = drawData.debugCPUPercent
        let overlayStr = String(format: "FPS: %.1f  CPU: %.1f%%", fps, cpu)
        let changed = (overlayStr != lastOverlayString)
        if !changed && (now - lastOverlayUpdateTime) < overlayUpdateInterval {
            return
        }
        lastOverlayString = overlayStr
        lastOverlayUpdateTime = now

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: 14,
            weight: .regular
        )
        let fuchsia = NSColor(
            calibratedRed: 1.0,
            green: 0.0,
            blue: 1.0,
            alpha: 1.0
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fuchsia,
        ]
        let textSize = (overlayStr as NSString).size(withAttributes: attributes)
        let padH: CGFloat = 8
        let padV: CGFloat = 4
        let texWidth = Int(ceil(textSize.width + padH * 2))
        let texHeight = Int(ceil(textSize.height + padV * 2))

        let maxW = 1024
        let maxH = 256
        overlayWidthPx = min(texWidth, maxW)
        overlayHeightPx = min(texHeight, maxH)
        let rowBytes = overlayWidthPx * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * overlayHeightPx)

        if let ctx = CGContext(
            data: &bytes,
            width: overlayWidthPx,
            height: overlayHeightPx,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.clear(
                CGRect(
                    x: 0,
                    y: 0,
                    width: overlayWidthPx,
                    height: overlayHeightPx
                )
            )
            ctx.setFillColor(
                NSColor(
                    calibratedRed: 0.05,
                    green: 0.0,
                    blue: 0.08,
                    alpha: 0.55
                ).cgColor
            )
            ctx.fill(
                CGRect(
                    x: 0,
                    y: 0,
                    width: overlayWidthPx,
                    height: overlayHeightPx
                )
            )

            let nsGC = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsGC
            (overlayStr as NSString).draw(
                at: CGPoint(x: padH, y: padV),
                withAttributes: attributes
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        if overlayTexture == nil || overlayTexture!.width != overlayWidthPx
            || overlayTexture!.height != overlayHeightPx
        {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: overlayWidthPx,
                height: overlayHeightPx,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            overlayTexture = device.makeTexture(descriptor: desc)
            overlayTexture?.label = "DebugOverlay"
        }
        if let tex = overlayTexture {
            let region = MTLRegionMake2D(0, 0, overlayWidthPx, overlayHeightPx)
            tex.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: bytes,
                bytesPerRow: rowBytes
            )
        }

        os_log(
            "Overlay updated (size=%dx%d text=\"%{public}@\" eff=%{public}@ engine=%{public}@ user=%{public}@ color=fuchsia)",
            log: log,
            type: .info,
            overlayWidthPx,
            overlayHeightPx,
            overlayStr,
            effectiveEnabled ? "ON" : "off",
            drawData.debugOverlayEnabled ? "ON" : "off",
            "(n/a)"
        )

        buildOverlayQuadIfNeeded(screenSize: drawData.size)
    }

    private func buildOverlayQuadIfNeeded(screenSize: CGSize) {
        guard overlayWidthPx > 0, overlayHeightPx > 0 else { return }
        let margin: CGFloat = 8
        let W = screenSize.width
        let H = screenSize.height
        guard W > 0 && H > 0 else { return }
        let texW = CGFloat(max(overlayWidthPx, 1))
        let texH = CGFloat(max(overlayHeightPx, 1))
        let scaleX = texW / max(W, 1)
        let scaleY = texH / max(H, 1)
        let overlayWidthPts = texW / max(scaleX, 1)
        let overlayHeightPts = texH / max(scaleY, 1)
        let x0: CGFloat = margin
        let y0: CGFloat = margin
        let x1: CGFloat = min(x0 + overlayWidthPts, W)
        let y1: CGFloat = min(y0 + overlayHeightPts, H)

        func toClipX(_ x: CGFloat) -> Float {
            return Float((x / W) * 2.0 - 1.0)
        }
        func toClipY(_ y: CGFloat) -> Float {
            return Float(1.0 - (y / H) * 2.0)
        }

        let tl = SIMD2<Float>(toClipX(x0), toClipY(y0))
        let tr = SIMD2<Float>(toClipX(x1), toClipY(y0))
        let bl = SIMD2<Float>(toClipX(x0), toClipY(y1))
        let br = SIMD2<Float>(toClipX(x1), toClipY(y1))

        struct V {
            var p: SIMD2<Float>
            var t: SIMD2<Float>
        }
        let verts: [V] = [
            V(p: bl, t: [0, 1]),
            V(p: br, t: [1, 1]),
            V(p: tl, t: [0, 0]),
            V(p: tl, t: [0, 0]),
            V(p: br, t: [1, 1]),
            V(p: tr, t: [1, 0]),
        ]
        let len = MemoryLayout<V>.stride * verts.count
        if overlayQuadVertexBuffer == nil
            || overlayQuadVertexBuffer!.length < len
        {
            overlayQuadVertexBuffer = device.makeBuffer(
                bytes: verts,
                length: len,
                options: .storageModeShared
            )
            overlayQuadVertexBuffer?.label = "OverlayQuad"
        } else {
            memcpy(overlayQuadVertexBuffer!.contents(), verts, len)
        }
    }

    func drawOverlayIfNeeded(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        frameIndex: UInt64,
        drawData: StarryDrawData,
        effectiveOverlayEnabled: Bool,
        engineOverlayEnabled: Bool,
        userOverlayEnabled: Bool
    ) {
        guard effectiveOverlayEnabled,
            let overlayTex = overlayTexture,
            let overlayVB = overlayQuadVertexBuffer
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(overlayVB, offset: 0, index: 0)
        encoder.setFragmentTexture(overlayTex, index: 0)
        var whiteTint = SIMD4<Float>(1, 1, 1, 1)
        encoder.setFragmentBytes(
            &whiteTint,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        lastOverlayDrawnFrame = frameIndex
        let now = CACurrentMediaTime()
        if now - lastOverlayLogTime > 2.0 {
            os_log(
                "Overlay drawn (frame=%{public}llu size=%{public}dx%{public}d text=\"%{public}@\" eff=%{public}@ engine=%{public}@ user=%{public}@)",
                log: log,
                type: .info,
                frameIndex,
                overlayTex.width,
                overlayTex.height,
                lastOverlayString,
                effectiveOverlayEnabled ? "ON" : "off",
                engineOverlayEnabled ? "ON" : "off",
                userOverlayEnabled ? "ON" : "off"
            )
            lastOverlayLogTime = now
        }
    }

    func updateBuildInfo(text: String, screenSize: CGSize) {
        guard !text.isEmpty else { return }
        let screenSizeChanged = screenSize != buildInfoLastScreenSize
        if buildInfoRendered && !screenSizeChanged { return }
        buildInfoLastScreenSize = screenSize

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let green = NSColor(
            calibratedRed: 0.0,
            green: 1.0,
            blue: 0.0,
            alpha: 1.0
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: green,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padH: CGFloat = 6
        let padV: CGFloat = 3
        let texWidth = Int(ceil(textSize.width + padH * 2))
        let texHeight = Int(ceil(textSize.height + padV * 2))

        let maxW = 1024
        let maxH = 128
        buildInfoWidthPx = min(texWidth, maxW)
        buildInfoHeightPx = min(texHeight, maxH)
        let rowBytes = buildInfoWidthPx * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * buildInfoHeightPx)

        if let ctx = CGContext(
            data: &bytes,
            width: buildInfoWidthPx,
            height: buildInfoHeightPx,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.clear(
                CGRect(
                    x: 0,
                    y: 0,
                    width: buildInfoWidthPx,
                    height: buildInfoHeightPx
                )
            )
            ctx.setFillColor(
                NSColor(
                    calibratedRed: 0.0,
                    green: 0.05,
                    blue: 0.0,
                    alpha: 0.55
                ).cgColor
            )
            ctx.fill(
                CGRect(
                    x: 0,
                    y: 0,
                    width: buildInfoWidthPx,
                    height: buildInfoHeightPx
                )
            )

            let nsGC = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsGC
            (text as NSString).draw(
                at: CGPoint(x: padH, y: padV),
                withAttributes: attributes
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        if buildInfoTexture == nil || buildInfoTexture!.width != buildInfoWidthPx
            || buildInfoTexture!.height != buildInfoHeightPx
        {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: buildInfoWidthPx,
                height: buildInfoHeightPx,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            buildInfoTexture = device.makeTexture(descriptor: desc)
            buildInfoTexture?.label = "BuildInfoOverlay"
        }
        if let tex = buildInfoTexture {
            let region = MTLRegionMake2D(0, 0, buildInfoWidthPx, buildInfoHeightPx)
            tex.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: bytes,
                bytesPerRow: rowBytes
            )
        }

        buildBuildInfoQuad(screenSize: screenSize)
        buildInfoRendered = true
    }

    private func buildBuildInfoQuad(screenSize: CGSize) {
        guard buildInfoWidthPx > 0, buildInfoHeightPx > 0 else { return }
        let margin: CGFloat = 8
        let W = screenSize.width
        let H = screenSize.height
        guard W > 0 && H > 0 else { return }

        let x1: CGFloat = W - margin
        let x0: CGFloat = max(x1 - CGFloat(buildInfoWidthPx), 0)
        let y1: CGFloat = H - margin
        let y0: CGFloat = max(y1 - CGFloat(buildInfoHeightPx), 0)

        func toClipX(_ x: CGFloat) -> Float {
            return Float((x / W) * 2.0 - 1.0)
        }
        func toClipY(_ y: CGFloat) -> Float {
            return Float(1.0 - (y / H) * 2.0)
        }

        let tl = SIMD2<Float>(toClipX(x0), toClipY(y0))
        let tr = SIMD2<Float>(toClipX(x1), toClipY(y0))
        let bl = SIMD2<Float>(toClipX(x0), toClipY(y1))
        let br = SIMD2<Float>(toClipX(x1), toClipY(y1))

        struct V {
            var p: SIMD2<Float>
            var t: SIMD2<Float>
        }
        let verts: [V] = [
            V(p: bl, t: [0, 1]),
            V(p: br, t: [1, 1]),
            V(p: tl, t: [0, 0]),
            V(p: tl, t: [0, 0]),
            V(p: br, t: [1, 1]),
            V(p: tr, t: [1, 0]),
        ]
        let len = MemoryLayout<V>.stride * verts.count
        if buildInfoQuadVertexBuffer == nil
            || buildInfoQuadVertexBuffer!.length < len
        {
            buildInfoQuadVertexBuffer = device.makeBuffer(
                bytes: verts,
                length: len,
                options: .storageModeShared
            )
            buildInfoQuadVertexBuffer?.label = "BuildInfoQuad"
        } else {
            memcpy(buildInfoQuadVertexBuffer!.contents(), verts, len)
        }
    }

    func drawBuildInfoIfNeeded(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState
    ) {
        guard let tex = buildInfoTexture,
            let vb = buildInfoQuadVertexBuffer
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.setFragmentTexture(tex, index: 0)
        var whiteTint = SIMD4<Float>(1, 1, 1, 1)
        encoder.setFragmentBytes(
            &whiteTint,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    func encodeClearOverlayTextureIfNeeded(commandBuffer: MTLCommandBuffer) {
        guard let tex = overlayTexture else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            enc.pushDebugGroup("Clear DebugOverlay")
            let vp = MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(tex.width),
                height: Double(tex.height),
                znear: 0,
                zfar: 1
            )
            enc.setViewport(vp)
            enc.popDebugGroup()
            enc.endEncoding()
        }
    }
}
