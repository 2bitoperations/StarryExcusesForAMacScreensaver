#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_FILE="$PROJECT_DIR/StarryExcuseForAMacScreensaver.xcodeproj"
SCHEME="StarryPreview"

SATURN_PNG="$TMPDIR/saturn.png"
JUPITER_PNG="$TMPDIR/jupiter.png"
ANALYZER_SWIFT="$TMPDIR/analyze_alignment.swift"
ANALYZER_BIN="$TMPDIR/analyze_alignment"

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

run_capture() {
  local output_png="$1"
  shift
  "$PREVIEW_BIN" \
    --screenshot "$output_png" \
    --debug-moon-colors \
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
    "$@"
}

echo "==> Capturing Saturn-only screenshot"
run_capture "$SATURN_PNG" \
  --mercury-size 0 \
  --venus-size 0 \
  --mars-size 0 \
  --jupiter-size 0 \
  --saturn-size 0.10 \
  --uranus-size 0 \
  --neptune-size 0 \
  --pluto-size 0 \
  --saturn-ring-tilt 25.0 \
  --saturn-ring-rotation 45.0

echo "==> Capturing Jupiter-only screenshot"
run_capture "$JUPITER_PNG" \
  --mercury-size 0 \
  --venus-size 0 \
  --mars-size 0 \
  --jupiter-size 0.10 \
  --saturn-size 0 \
  --uranus-size 0 \
  --neptune-size 0 \
  --pluto-size 0

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

func moonDebugColorMask(width: Int, height: Int, rgba: [UInt8], moonName: String, skyMinY: Int, skyMaxY: Int) -> [Bool] {
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

            let matched: Bool
            switch moonName.lowercased() {
            case "io":
                matched = (r > 200 && g < 50 && b < 50)
            case "europa":
                matched = (g > 200 && r < 50 && b < 50)
            case "ganymede":
                matched = (b > 200 && r < 50 && g < 50)
            case "callisto":
                matched = (r > 200 && g > 200 && b < 50)
            case "titan":
                matched = (r > 200 && b > 200 && g < 50)
            default:
                matched = false
            }
            if matched {
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

func angleDeg(from center: (Double, Double), to point: (Double, Double)) -> Double {
    let dx = point.0 - center.0
    let dyImage = point.1 - center.1
    let dyCartesian = -dyImage
    let radians = atan2(dyCartesian, dx)
    var deg = radians * 180.0 / .pi
    if deg < 0 { deg += 360.0 }
    return deg
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
    let adaptive = Int(Double(maxSum) * 0.55)
    return max(25, min(240, adaptive))
}

func angleDistanceDeg(_ a: Double, _ b: Double) -> Double {
    var d = abs(a - b).truncatingRemainder(dividingBy: 360.0)
    if d > 180.0 { d = 360.0 - d }
    return d
}

func nearestAxisDistanceDeg(measured: Double, axes: [Double]) -> Double {
    var best = Double.greatestFiniteMagnitude
    for axis in axes {
        best = min(best, angleDistanceDeg(measured, axis))
    }
    return best
}

func analyze(
    imagePath: String,
    name: String,
    debugColors: Bool,
    debugMoonNames: [String],
    expectedAxesDeg: [Double],
    toleranceDeg: Double,
    planetMinClusterSize: Int,
    nearScaleMin: Double,
    nearScaleMax: Double,
    moonSizeMin: Int,
    moonSizeMax: Int,
    minMoonCandidates: Int
) -> Bool {
    do {
        let (width, height, rgba) = try loadRGBA(imagePath)

        // Ignore the lower building area and focus on sky.
        let skyMinY = 0
        let skyMaxY = Int(Double(height) * 0.80)

        let threshold = estimateThreshold(width: width, height: height, rgba: rgba, skyMinY: skyMinY, skyMaxY: skyMaxY)
        if threshold == Int.max {
            print("\(name): FAIL - image appears fully black (no bright pixels)")
            return false
        }

        let mask = brightMask(
            width: width,
            height: height,
            rgba: rgba,
            threshold: threshold,
            skyMinY: skyMinY,
            skyMaxY: skyMaxY
        )
        var allClusters = clusters(width: width, height: height, mask: mask)
        allClusters = allClusters.filter { $0.size >= 2 }

        guard let planet = allClusters
            .filter({ $0.size >= planetMinClusterSize })
            .max(by: { $0.size < $1.size })
        else {
            print("\(name): FAIL - no plausible planet cluster (threshold=\(threshold), clusters=\(allClusters.count))")
            return false
        }

        let planetCenter = (planet.centroidX, planet.centroidY)
        let planetRadius = Double(max(planet.width, planet.height)) * 0.5

        let candidates: [Cluster]
        if debugColors {
            var debugCandidates: [Cluster] = []
            for moonName in debugMoonNames {
                let colorMask = moonDebugColorMask(
                    width: width,
                    height: height,
                    rgba: rgba,
                    moonName: moonName,
                    skyMinY: skyMinY,
                    skyMaxY: skyMaxY
                )
                let moonClusters = clusters(width: width, height: height, mask: colorMask)
                    .filter { c in
                        if c.size < moonSizeMin || c.size > moonSizeMax { return false }
                        let dx = c.centroidX - planetCenter.0
                        let dy = c.centroidY - planetCenter.1
                        let dist = sqrt(dx * dx + dy * dy)
                        return dist >= nearScaleMin * planetRadius && dist <= nearScaleMax * planetRadius
                    }
                debugCandidates.append(contentsOf: moonClusters)
            }
            candidates = debugCandidates
        } else {
            candidates = allClusters.filter { c in
                if c.size < moonSizeMin || c.size > moonSizeMax { return false }
                let dx = c.centroidX - planetCenter.0
                let dy = c.centroidY - planetCenter.1
                let dist = sqrt(dx * dx + dy * dy)
                return dist >= nearScaleMin * planetRadius && dist <= nearScaleMax * planetRadius
            }
        }

        if candidates.count < minMoonCandidates {
            print("\(name): FAIL - insufficient moon candidates (found \(candidates.count), need \(minMoonCandidates))")
            return false
        }

        let evaluated = candidates.map { c -> (angle: Double, distance: Double, score: Double) in
            let ang = angleDeg(from: planetCenter, to: (c.centroidX, c.centroidY))
            let deviation = nearestAxisDistanceDeg(measured: ang, axes: expectedAxesDeg)
            return (ang, deviation, deviation)
        }
        let best = evaluated.min(by: { $0.score < $1.score })!

        let aligned = best.distance <= toleranceDeg
        let outcome = aligned ? "PASS" : "FAIL"
        print(
            "\(name): \(outcome) - bestMoonAngle=\(String(format: "%.2f", best.angle))°, axisDeviation=\(String(format: "%.2f", best.distance))°, tolerance=±\(String(format: "%.2f", toleranceDeg))°, moonCandidates=\(candidates.count), threshold=\(threshold), planetClusterSize=\(planet.size)"
        )

        return aligned
    } catch {
        print("\(name): FAIL - analysis error: \(error)")
        return false
    }
}

var debugColors = false
var positional: [String] = []
for arg in CommandLine.arguments.dropFirst() {
    if arg == "--debug-colors" {
        debugColors = true
    } else {
        positional.append(arg)
    }
}

if positional.count != 2 {
    fputs("Usage: analyze_alignment [--debug-colors] <saturn_png> <jupiter_png>\n", stderr)
    exit(2)
}

let saturnPNG = positional[0]
let jupiterPNG = positional[1]

let saturnCheck = analyze(
    imagePath: saturnPNG,
    name: "Saturn/Titan alignment",
    debugColors: debugColors,
    debugMoonNames: ["Titan"],
    expectedAxesDeg: [45.0, 225.0],
    toleranceDeg: 30.0,
    planetMinClusterSize: 150,
    nearScaleMin: 1.8,
    nearScaleMax: 3.6,
    moonSizeMin: 1,
    moonSizeMax: 18,
    minMoonCandidates: 1
)

let jupiterCheck = analyze(
    imagePath: jupiterPNG,
    name: "Jupiter/Galilean control",
    debugColors: debugColors,
    debugMoonNames: ["Io", "Europa", "Ganymede", "Callisto"],
    expectedAxesDeg: [0.0, 180.0],
    toleranceDeg: 15.0,
    planetMinClusterSize: 150,
    nearScaleMin: 1.8,
    nearScaleMax: 5.5,
    moonSizeMin: 1,
    moonSizeMax: 18,
    minMoonCandidates: 1
)

print("")
if saturnCheck && jupiterCheck {
    print("Overall: PASS")
    exit(0)
} else {
    print("Overall: FAIL")
    exit(1)
}
SWIFT

echo "==> Building inline analyzer"
swiftc "$ANALYZER_SWIFT" -o "$ANALYZER_BIN"

echo "==> Running moon alignment analysis"
set +e
"$ANALYZER_BIN" --debug-colors "$SATURN_PNG" "$JUPITER_PNG"
ANALYSIS_EXIT=$?
set -e

if [ "$ANALYSIS_EXIT" -ne 0 ]; then
  echo ""
  echo "Expected currently buggy behavior: Saturn should fail while Jupiter control should pass."
  echo "If both fail, screenshot capture may be unavailable/blank in this environment."
fi

exit "$ANALYSIS_EXIT"
