#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_FILE="$PROJECT_DIR/StarryExcuseForAMacScreensaver.xcodeproj"
SCHEME="StarryPreview"

SATURN_PNG="$TMPDIR/saturn_ring_test.png"
ANALYZER_SWIFT="$TMPDIR/analyze_saturn_ring_clipping.swift"
ANALYZER_BIN="$TMPDIR/analyze_saturn_ring_clipping"

echo "==> Building $SCHEME (Debug)"
xcodebuild -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration Debug build -quiet

BUILD_SETTINGS="$TMPDIR/build-settings.txt"
xcodebuild -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration Debug -showBuildSettings > "$BUILD_SETTINGS"

TARGET_BUILD_DIR="$(python3 - <<'PY' "$BUILD_SETTINGS"
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"^\s*TARGET_BUILD_DIR\s*=\s*(.+)$", text, re.MULTILINE)
if not match:
    raise SystemExit("Could not locate TARGET_BUILD_DIR in xcodebuild output")
print(match.group(1).strip())
PY
)"

PREVIEW_BIN="$TARGET_BUILD_DIR/StarryPreview.app/Contents/MacOS/StarryPreview"
if [ ! -x "$PREVIEW_BIN" ]; then
  echo "ERROR: StarryPreview binary not found at: $PREVIEW_BIN"
  exit 1
fi

echo "==> Capturing Saturn screenshot for ring clipping analysis"
"$PREVIEW_BIN" \
  --screenshot "$SATURN_PNG" \
  --width 900 \
  --height 700 \
  --frames 50 \
  --star-density 0 \
  --building-lights-density 0 \
  --building-height 0.1 \
  --building-frequency 0.001 \
  --moon-diameter 0.001 \
  --shooting-stars false \
  --satellites false \
  --secs-between-clears 1 \
  --planet-position-mode random \
  --mercury-size 0 \
  --venus-size 0 \
  --mars-size 0 \
  --jupiter-size 0 \
  --saturn-size 0.15 \
  --uranus-size 0 \
  --neptune-size 0 \
  --pluto-size 0 \
  --saturn-ring-tilt 25.0 \
  --saturn-ring-rotation 45.0

cat > "$ANALYZER_SWIFT" <<'SWIFT'
import AppKit
import Foundation

struct Cluster {
    let count: Int
    let sumX: Double
    let sumY: Double
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int

    var size: Int { count }
    var centroidX: Double { sumX / Double(size) }
    var centroidY: Double { sumY / Double(size) }
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

func loadRGBA(_ path: String) throws -> (width: Int, height: Int, data: [UInt8]) {
    guard let image = NSImage(contentsOfFile: path) else {
        throw NSError(domain: "analyze", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load image at \(path)"])
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else {
        throw NSError(domain: "analyze", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode image data at \(path)"])
    }

    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    var rgba = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
        for x in 0..<width {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let idx = (y * width + x) * 4
            rgba[idx + 0] = UInt8(max(0, min(255, Int(round(color.redComponent * 255.0)))))
            rgba[idx + 1] = UInt8(max(0, min(255, Int(round(color.greenComponent * 255.0)))))
            rgba[idx + 2] = UInt8(max(0, min(255, Int(round(color.blueComponent * 255.0)))))
            rgba[idx + 3] = UInt8(max(0, min(255, Int(round(color.alphaComponent * 255.0)))))
        }
    }

    return (width, height, rgba)
}

func estimateThreshold(width: Int, height: Int, rgba: [UInt8], skyMinY: Int, skyMaxY: Int) -> Int {
    let y0 = max(0, skyMinY)
    let y1 = min(height - 1, skyMaxY)
    if y1 < y0 { return 120 }

    var maxSum = 0
    for y in y0...y1 {
        for x in 0..<width {
            let idx = (y * width + x) * 4
            let s = Int(rgba[idx + 0]) + Int(rgba[idx + 1]) + Int(rgba[idx + 2])
            if s > maxSum { maxSum = s }
        }
    }

    if maxSum <= 0 { return Int.max }
    let adaptive = Int(Double(maxSum) * 0.45)
    return max(18, min(240, adaptive))
}

func brightMask(width: Int, height: Int, rgba: [UInt8], threshold: Int, skyMinY: Int, skyMaxY: Int) -> [Bool] {
    var mask = [Bool](repeating: false, count: width * height)
    let y0 = max(0, skyMinY)
    let y1 = min(height - 1, skyMaxY)
    if y1 < y0 { return mask }

    for y in y0...y1 {
        for x in 0..<width {
            let idx = (y * width + x) * 4
            let r = Int(rgba[idx + 0])
            let g = Int(rgba[idx + 1])
            let b = Int(rgba[idx + 2])
            if (r + g + b) >= threshold {
                mask[y * width + x] = true
            }
        }
    }
    return mask
}

func clusters(width: Int, height: Int, mask: [Bool]) -> [Cluster] {
    var visited = [Bool](repeating: false, count: width * height)
    var out: [Cluster] = []
    let directions = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

    for y in 0..<height {
        for x in 0..<width {
            let startIdx = y * width + x
            if !mask[startIdx] || visited[startIdx] { continue }

            var queue: [(Int, Int)] = [(x, y)]
            var qHead = 0
            visited[startIdx] = true

            var count = 0
            var sumX = 0.0
            var sumY = 0.0
            var minX = x
            var maxX = x
            var minY = y
            var maxY = y

            while qHead < queue.count {
                let (cx, cy) = queue[qHead]
                qHead += 1

                count += 1
                sumX += Double(cx)
                sumY += Double(cy)
                minX = min(minX, cx)
                maxX = max(maxX, cx)
                minY = min(minY, cy)
                maxY = max(maxY, cy)

                for (dx, dy) in directions {
                    let nx = cx + dx
                    let ny = cy + dy
                    if nx < 0 || nx >= width || ny < 0 || ny >= height { continue }
                    let nIdx = ny * width + nx
                    if !mask[nIdx] || visited[nIdx] { continue }
                    visited[nIdx] = true
                    queue.append((nx, ny))
                }
            }

            out.append(
                Cluster(
                    count: count,
                    sumX: sumX,
                    sumY: sumY,
                    minX: minX,
                    maxX: maxX,
                    minY: minY,
                    maxY: maxY
                ))
        }
    }

    return out
}

func analyze(imagePath: String) -> Int32 {
    do {
        let (width, height, rgba) = try loadRGBA(imagePath)

        let skyMinY = 0
        let skyMaxY = Int(Double(height) * 0.80)

        let threshold = estimateThreshold(width: width, height: height, rgba: rgba, skyMinY: skyMinY, skyMaxY: skyMaxY)
        if threshold == Int.max {
            print("Saturn ring clipping: INCONCLUSIVE - image appears fully black (no bright pixels)")
            return 2
        }

        let mask = brightMask(width: width, height: height, rgba: rgba, threshold: threshold, skyMinY: skyMinY, skyMaxY: skyMaxY)
        let allClusters = clusters(width: width, height: height, mask: mask).filter { $0.size >= 2 }

        guard let saturn = allClusters
            .filter({ $0.size >= 220 })
            .max(by: { $0.size < $1.size })
        else {
            print("Saturn ring clipping: INCONCLUSIVE - no plausible Saturn cluster found (threshold=\(threshold), clusters=\(allClusters.count))")
            return 2
        }

        let centerX = Int(round(saturn.centroidX))
        let centerY = Int(round(saturn.centroidY))
        let clusterTop = saturn.minY
        let clusterBottom = saturn.maxY
        let clusterLeft = saturn.minX
        let clusterRight = saturn.maxX

        let margin = 12
        if centerX < margin || centerX >= width - margin || centerY < margin || centerY >= skyMaxY - margin {
            print("Saturn ring clipping: INCONCLUSIVE - Saturn too close to image/sky bounds (center=(\(centerX),\(centerY)), skyMaxY=\(skyMaxY))")
            return 2
        }

        // Estimate disc radius by scanning from center until bright region ends.
        var radiusUp = 0
        var y = centerY
        while y >= 0 && mask[y * width + centerX] {
            radiusUp += 1
            y -= 1
        }
        var radiusDown = 0
        y = centerY
        while y < height && mask[y * width + centerX] {
            radiusDown += 1
            y += 1
        }
        let estimatedDiscRadius = max(8, min(radiusUp, radiusDown))

        let ringTopExtension = max(0, centerY - clusterTop - estimatedDiscRadius)
        let ringBottomExtension = max(0, clusterBottom - centerY - estimatedDiscRadius)
        let ringLeftExtension = max(0, centerX - clusterLeft - estimatedDiscRadius)
        let ringRightExtension = max(0, clusterRight - centerX - estimatedDiscRadius)

        let totalVerticalRing = ringTopExtension + ringBottomExtension
        let asymmetry = abs(ringTopExtension - ringBottomExtension)
        let asymmetryRatio = totalVerticalRing > 0 ? Double(asymmetry) / Double(totalVerticalRing) : 1.0

        // Detect suspiciously flat clipping edges: many adjacent bright pixels exactly at top/bottom boundary rows.
        func maxBoundaryRun(atY boundaryY: Int) -> Int {
            guard boundaryY >= 0 && boundaryY < height else { return 0 }
            var best = 0
            var current = 0
            for x in max(0, clusterLeft - 2)...min(width - 1, clusterRight + 2) {
                if mask[boundaryY * width + x] {
                    current += 1
                    best = max(best, current)
                } else {
                    current = 0
                }
            }
            return best
        }

        let topBoundaryRun = maxBoundaryRun(atY: clusterTop)
        let bottomBoundaryRun = maxBoundaryRun(atY: clusterBottom)
        let maxBoundaryRunLen = max(topBoundaryRun, bottomBoundaryRun)
        let flatClipSuspected = maxBoundaryRunLen >= max(12, estimatedDiscRadius / 2)

        let severeAsymmetrySuspected = asymmetryRatio > 0.45 && totalVerticalRing >= 8
        let noVerticalRingDetected = totalVerticalRing < 4

        print("Saturn diagnostics:")
        print("  threshold=\(threshold), clusterSize=\(saturn.size), bbox=[x:\(clusterLeft)...\(clusterRight), y:\(clusterTop)...\(clusterBottom)], center=(\(centerX),\(centerY))")
        print("  estimatedDiscRadius=\(estimatedDiscRadius)")
        print("  ringExtensions px: top=\(ringTopExtension), bottom=\(ringBottomExtension), left=\(ringLeftExtension), right=\(ringRightExtension)")
        print("  verticalRingTotal=\(totalVerticalRing), asymmetry=\(asymmetry), asymmetryRatio=\(String(format: "%.3f", asymmetryRatio))")
        print("  boundaryRuns: top=\(topBoundaryRun), bottom=\(bottomBoundaryRun), max=\(maxBoundaryRunLen)")

        let clippingDetected = flatClipSuspected || severeAsymmetrySuspected || noVerticalRingDetected

        if clippingDetected {
            var reasons: [String] = []
            if flatClipSuspected { reasons.append("flat ring edge at cluster boundary") }
            if severeAsymmetrySuspected { reasons.append("strong vertical asymmetry") }
            if noVerticalRingDetected { reasons.append("insufficient vertical ring extent") }
            print("Saturn ring clipping: FAIL - clipping suspected (\(reasons.joined(separator: ", ")))")
            return 1
        } else {
            print("Saturn ring clipping: PASS - no clipping indicators detected")
            return 0
        }
    } catch {
        print("Saturn ring clipping: INCONCLUSIVE - analysis error: \(error)")
        return 2
    }
}

if CommandLine.arguments.count != 2 {
    fputs("Usage: analyze_saturn_ring_clipping <saturn_png>\n", stderr)
    exit(2)
}

let exitCode = analyze(imagePath: CommandLine.arguments[1])
exit(exitCode)
SWIFT

echo "==> Building inline analyzer"
swiftc "$ANALYZER_SWIFT" -o "$ANALYZER_BIN"

echo "==> Running Saturn ring clipping analysis"
set +e
"$ANALYZER_BIN" "$SATURN_PNG"
ANALYSIS_EXIT=$?
set -e

if [ "$ANALYSIS_EXIT" -eq 2 ]; then
  echo ""
  echo "Saturn ring clipping: INCONCLUSIVE (Saturn not found reliably or image capture unavailable)."
  echo "Treat as test infrastructure/environment issue, not a PASS."
fi

exit "$ANALYSIS_EXIT"
