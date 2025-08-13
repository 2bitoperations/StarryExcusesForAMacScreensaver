import Cocoa
import CoreGraphics

// Lightweight preview renderer for the configuration sheet.
// Renders: background, some random stars, a few building silhouettes, and the moon
// with current configuration (approximation only).
class MoonPreviewView: NSView {
    
    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let b: CGFloat
    }
    
    private var stars: [Star] = []
    
    private var phaseFraction: Double = 0.5
    private var waxing: Bool = true
    private var minRadius: Int = 15
    private var maxRadius: Int = 60
    private var brightBrightness: Double = 1.0
    private var darkBrightness: Double = 0.15
    private var traversalMinutes: Int = 60
    private var buildingHeightFraction: Double = 0.35
    
    private var previewMoonRadius: Int = 30
    
    func configure(phaseFraction: Double,
                   waxing: Bool,
                   minRadius: Int,
                   maxRadius: Int,
                   brightBrightness: Double,
                   darkBrightness: Double,
                   traversalMinutes: Int,
                   buildingHeightFraction: Double) {
        self.phaseFraction = phaseFraction
        self.waxing = waxing
        self.minRadius = minRadius
        self.maxRadius = max(maxRadius, minRadius)
        self.brightBrightness = brightBrightness
        self.darkBrightness = darkBrightness
        self.traversalMinutes = traversalMinutes
        self.buildingHeightFraction = buildingHeightFraction
        self.previewMoonRadius = (self.minRadius + self.maxRadius) / 2
        if stars.isEmpty {
            generateStars()
        }
    }
    
    private func generateStars() {
        // deterministic seed
        let width = bounds.width
        let height = bounds.height
        let count = 80
        for i in 0..<count {
            let fx = CGFloat((i * 73) % Int(width))
            let fy = CGFloat((i * 137) % Int(height))
            let b = CGFloat(0.3 + (Double((i * 199) % 100) / 100.0) * 0.7)
            stars.append(Star(x: fx, y: fy, b: b))
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        drawBackground(ctx)
        drawBuildings(ctx)
        drawStars(ctx)
        drawMoon(ctx)
        ctx.restoreGState()
    }
    
    private func drawBackground(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        ctx.fill(bounds)
    }
    
    private func drawBuildings(_ ctx: CGContext) {
        let maxH = bounds.height * CGFloat(buildingHeightFraction)
        let baseY: CGFloat = 0
        let w = bounds.width
        let buildingCount = 8
        for i in 0..<buildingCount {
            let bw = CGFloat(20 + (i * 37) % 60)
            let bh = CGFloat(10 + (i * 53) % Int(maxH))
            let x = CGFloat((i * 97) % Int(w))
            let rect = CGRect(x: x, y: baseY, width: bw, height: bh)
            ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.0, alpha: 1.0))
            ctx.fill(rect)
        }
    }
    
    private func drawStars(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        for s in stars {
            ctx.setFillColor(CGColor(gray: s.b, alpha: 1.0))
            ctx.fill(CGRect(x: s.x, y: s.y, width: 1, height: 1))
        }
    }
    
    private func drawMoon(_ ctx: CGContext) {
        let r = CGFloat(previewMoonRadius)
        let center = CGPoint(x: bounds.width * 0.65, y: bounds.height * 0.6)
        let f = CGFloat(max(0.0, min(1.0, phaseFraction)))
        let moonRect = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)
        
        // Full/new thresholds
        let newT: CGFloat = 0.005
        let fullT: CGFloat = 0.995
        
        let bright = CGFloat(brightBrightness)
        let dark = CGFloat(darkBrightness)
        
        ctx.interpolationQuality = .none
        
        // Simple textured-like fill via noise (avoid duplicating full texture code)
        func fillDisc(brightness: CGFloat) {
            ctx.saveGState()
            ctx.addEllipse(in: moonRect)
            ctx.clip()
            // coarse blocks
            let block = max(2, Int(r / 8))
            for y in stride(from: Int(moonRect.minY), to: Int(moonRect.maxY), by: block) {
                for x in stride(from: Int(moonRect.minX), to: Int(moonRect.maxX), by: block) {
                    let hash = (x * 73856093) ^ (y * 19349663)
                    let v = CGFloat((hash & 255)) / 255.0
                    let adj = brightness * (0.85 + 0.3 * (v - 0.5))
                    ctx.setFillColor(CGColor(gray: max(0, min(1, adj)), alpha: 1.0))
                    ctx.fill(CGRect(x: x, y: y, width: block, height: block))
                }
            }
            ctx.restoreGState()
        }
        
        if f <= newT {
            fillDisc(brightness: dark)
            return
        } else if f >= fullT {
            fillDisc(brightness: bright)
            return
        }
        
        // Phase geometry
        let cosTheta = 1.0 - 2.0 * f
        let minorScale = abs(cosTheta)
        let ellipseWidth = max(0.5, 2.0 * r * minorScale)
        let ellipseRect = CGRect(x: center.x - ellipseWidth/2.0, y: center.y - r, width: ellipseWidth, height: 2*r)
        let crescent = f < 0.5
        
        // Base disc
        fillDisc(brightness: crescent ? dark : bright)
        
        // Overlay logic
        ctx.saveGState()
        ctx.addEllipse(in: moonRect)
        ctx.clip()
        let overlap: CGFloat = 1.0
        let centerX = center.x
        if crescent {
            // Add bright side then carve ellipse interior back dark
            let sideRect: CGRect
            if waxing {
                sideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            } else {
                sideRect = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            }
            ctx.saveGState()
            ctx.clip(to: sideRect)
            fillDisc(brightness: bright)
            ctx.restoreGState()
            // Carve
            ctx.saveGState()
            ctx.addEllipse(in: ellipseRect)
            ctx.clip()
            fillDisc(brightness: dark)
            ctx.restoreGState()
        } else {
            // Gibbous – dark outer sliver
            let sideRect: CGRect
            if waxing {
                // dark left
                sideRect = CGRect(x: centerX - r, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            } else {
                sideRect = CGRect(x: centerX - overlap, y: moonRect.minY, width: r + overlap, height: moonRect.height)
            }
            ctx.saveGState()
            ctx.clip(to: sideRect)
            fillDisc(brightness: dark)
            ctx.restoreGState()
            // Carve
            ctx.saveGState()
            ctx.addEllipse(in: ellipseRect)
            ctx.clip()
            fillDisc(brightness: bright)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
