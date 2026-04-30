import CoreGraphics
import Foundation
import os
import simd

enum PlanetIdentity: String, CaseIterable {
    case mercury, venus, mars, jupiter, saturn, uranus, neptune, pluto
}

// Represents a solar-system planet as a visible sky object, positioned using
// simplified Keplerian orbital mechanics rather than a wall-clock arc.
//
// Astronomy pipeline:
//   1. Look up J2000.0 Keplerian elements for the requested planet.
//   2. Compute heliocentric ecliptic longitude by propagating elements to the
//      requested date.
//   3. Convert to geocentric ecliptic coordinates by subtracting Earth's
//      heliocentric position (same element approach for Earth).
//   4. Rotate ecliptic → equatorial (J2000 obliquity 23.4393°).
//   5. Compute Hour Angle for the hardcoded Austin TX observer and derive
//      local horizontal coordinates (altitude, azimuth).
//   6. Map altitude/azimuth to screen space using the same horizon-line
//      convention as the skyline.
//
// Below-horizon behavior:
//   "hide"           → isAboveHorizon == false, center is off-screen.
//   "randomPosition" → a deterministic, day-stable position is returned and
//                      isAboveHorizon is reported as false so callers can
//                      optionally dim/annotate. Brightness is still 1.0.
//
// Screen mapping:
//   Altitude  0° → spawnMinY (bottom of shooting-star spawn box)
//   Altitude 90° → spawnMaxY - radius (top of spawn box, inset by planet radius)
//   Azimuth 180° (S) → screen centre; 0°/360° (N) → spawn box left/right edges.
//
struct Planet {

    struct MoonSpriteState {
        let name: String
        let center: CGPoint
        let sizePx: Float
        let color: SIMD3<Float>
        let alpha: Float
    }

    // MARK: - Observer (Austin, TX)

    static let observerLatDeg:  Double =  30.2672
    static let observerLonDeg:  Double = -97.7431

    // MARK: - Stored Properties

    let identity:     PlanetIdentity
    let screenWidth:  Int
    let screenHeight: Int
    let radius:       Int

    /// "hide", "random", or "randomWhenBelow" — controls planet positioning.
    let belowHorizonBehavior: String

    /// Spawn-box bounds matching the shooting-star coordinate space (pixels from bottom).
    private let spawnMinX: Double
    private let spawnMaxX: Double
    private let spawnMinY: Double
    private let spawnMaxY: Double

    /// Texture image produced by PlanetTexture (may be nil on first integration).
    let textureImage: CGImage?

    /// Per-engine-lifetime nonce mixed into the off-horizon RNG seed so that
    /// below-horizon positions differ each time the engine is recreated, while
    /// remaining stable for the lifetime of a single engine instance.
    let nonce: UInt64

    // MARK: - Init

    init(
        identity:              PlanetIdentity,
        screenWidth:           Int,
        screenHeight:          Int,
        buildingMaxHeight:     Int,
        log:                   OSLog,
        radius:                Int,
        belowHorizonBehavior:  String = "randomWhenBelow",
        nonce:                 UInt64 = 0
    ) {
        self.identity             = identity
        self.screenWidth          = screenWidth
        self.screenHeight         = screenHeight
        self.radius               = max(1, radius)
        self.belowHorizonBehavior = belowHorizonBehavior
        self.nonce                = nonce

        // Spawn box: mirrors the rectangle used by ShootingStarsLayerRenderer.
        let spawnMargin = 4
        let safeMinY    = buildingMaxHeight + spawnMargin
        self.spawnMinX  = Double(spawnMargin)
        self.spawnMaxX  = Double(screenWidth  - spawnMargin)
        self.spawnMinY  = Double(safeMinY     + spawnMargin + 8)
        self.spawnMaxY  = Double(screenHeight - spawnMargin)

        self.textureImage = PlanetTexture.createTexture(for: identity, diameter: max(1, radius) * 2)

        let (alt, az) = Planet.horizontalCoordinates(for: identity, now: Date())
        os_log(
            "Planet(%{public}@) init r=%{public}d alt=%.1f° az=%.1f° belowHorizonBehavior=%{public}@",
            log: log,
            type: .info,
            identity.rawValue,
            self.radius,
            alt,
            az,
            belowHorizonBehavior
        )
    }

    // MARK: - Public API

    /// Returns the per-frame display state for the planet.
    ///
    /// - Parameter now: The date/time to evaluate (defaults to wall-clock now).
    /// - Returns:
    ///   - `center`:         Screen position in points (origin bottom-left).
    ///   - `brightness`:     Render opacity.
    ///   - `isAboveHorizon`: True when the planet is geometrically above the
    ///                       horizon for Austin TX at the given time.
    ///   - `ringTiltDeg`:    Saturn ring opening angle B in degrees (−27° to +27°);
    ///                       0.0 for all other planets.
    ///   - `phaseFraction`:  Illuminated fraction (0.0=new, 1.0=full) from
    ///                       Sun–Earth–planet geometry.
    ///   - `waxingSign`:     +1.0 for waxing / -1.0 for waning, matching moon
    ///                       shader sign convention.
    func frameState(now: Date) -> (center: CGPoint, brightness: Float, isAboveHorizon: Bool, ringTiltDeg: Double, ringRotationDeg: Double, phaseFraction: Double, waxingSign: Double) {
        let (altDeg, azDeg) = Planet.horizontalCoordinates(for: identity, now: now)
        let aboveHorizon    = altDeg > 0.0
        let phase = Planet.phaseState(for: identity, now: now)

        let ringTilt: Double
        let ringRotation: Double
        if identity == .saturn {
            let (geoLon, geoLat) = Planet.geocentricEcliptic(for: .saturn, now: now)
            let d = Planet.julianDay(from: now) - 2451545.0
            ringTilt = Planet.saturnRingTilt(geocentricLonDeg: geoLon, geocentricLatDeg: geoLat, daysSinceJ2000: d)

            let (saturnRA, saturnDec) = Planet.geocentricEquatorialFromEcliptic(
                lonDeg: geoLon,
                latDeg: geoLat
            )
            ringRotation = Planet.saturnRingPositionAngle(saturnRARad: saturnRA, saturnDecRad: saturnDec)
        } else {
            ringTilt = 0.0
            ringRotation = 0.0
        }

        // If behavior is "random", ALWAYS use deterministicOffHorizonPoint (skip orbital check)
        switch belowHorizonBehavior {
        case "random":
            let center = deterministicOffHorizonPoint(now: now)
            return (center, 1.0, false, ringTilt, ringRotation, phase.fraction, phase.waxingSign)
        default:
            break
        }

        if aboveHorizon {
            let center = screenPoint(altitudeDeg: altDeg, azimuthDeg: azDeg)
            return (center, 1.0, true, ringTilt, ringRotation, phase.fraction, phase.waxingSign)
        }

        switch belowHorizonBehavior {
        case "randomWhenBelow":
            let center = deterministicOffHorizonPoint(now: now)
            return (center, 1.0, false, ringTilt, ringRotation, phase.fraction, phase.waxingSign)
        default: // "hide" and anything unrecognised
            let offScreen = CGPoint(x: -Double(radius) * 2, y: -Double(radius) * 2)
            return (offScreen, 0.0, false, ringTilt, ringRotation, phase.fraction, phase.waxingSign)
        }
    }

    static func moonSpriteStates(
        for parent: PlanetIdentity,
        now: Date,
        parentCenter: CGPoint,
        parentRadiusPx: Double,
        ringTiltDeg: Double,
        rotationDeg: Double
    ) -> [MoonSpriteState] {
        guard parentRadiusPx > 0 else { return [] }
        let defs = moonOrbitDefinitions[parent] ?? []
        guard !defs.isEmpty else { return [] }

        let daysSinceJ2000 = now.timeIntervalSince(j2000MoonEpochUTC) / 86400.0
        let baseReferenceRadiusPx: Double = parent == .jupiter ? 24.0 : 20.3
        let sizeScale = max(0.6, min(parentRadiusPx / baseReferenceRadiusPx, 1.8))

        let verticalForeshorten: Double
        if parent == .jupiter {
            verticalForeshorten = sin(toRad(3.0))
        } else {
            verticalForeshorten = sin(toRad(ringTiltDeg))
        }

        var states: [MoonSpriteState] = []
        states.reserveCapacity(defs.count)

        for moon in defs {
            let angle = (2.0 * Double.pi * daysSinceJ2000 / moon.periodDays) + moon.initialPhaseRad
            let x = moon.semiMajorAxisPlanetRadii * cos(angle)
            let y = moon.semiMajorAxisPlanetRadii * sin(angle)

            // Foreshorten FIRST (matches shader's R(θ)·S convention)
            let xp = x
            let yp = y * verticalForeshorten

            // THEN rotate in screen space
            let theta = rotationDeg * (Double.pi / 180.0)
            let xr = xp * cos(theta) - yp * sin(theta)
            let yr = xp * sin(theta) + yp * cos(theta)

            let screenX = parentCenter.x + xr * parentRadiusPx
            let screenY = parentCenter.y + yr * parentRadiusPx
            let screenCenter = CGPoint(x: screenX, y: screenY)

            let distanceToParentCenter = hypot(screenX - parentCenter.x, screenY - parentCenter.y)
            let isBehindPlanetDisc = (y > 0.0) && (distanceToParentCenter < parentRadiusPx)
            if isBehindPlanetDisc { continue }

            let moonSizePx = Float(min(3.0, max(1.0, moon.baseSizePx * sizeScale)))
            states.append(
                MoonSpriteState(
                    name: moon.name,
                    center: screenCenter,
                    sizePx: moonSizePx,
                    color: moon.color,
                    alpha: 0.78
                )
            )
        }

        return states
    }

    // MARK: - Screen Mapping

    /// Maps altitude [0°, 90°] and azimuth [0°, 360°] to a CGPoint within the spawn box.
    ///
    /// Vertical: altitude 0° → spawnMinY + radius, altitude 90° → spawnMaxY - radius.
    /// Horizontal: south (180°) → spawn box centre; all edges inset by radius.
    private func screenPoint(altitudeDeg: Double, azimuthDeg: Double) -> CGPoint {
        let altClamped  = min(max(altitudeDeg, 0.0), 90.0)
        let altFraction = altClamped / 90.0

        let bottomY = spawnMinY + Double(radius)
        let topY    = spawnMaxY - Double(radius)
        let y = bottomY + altFraction * (topY - bottomY)

        var relAz = azimuthDeg - 180.0
        if relAz < -180.0 { relAz += 360.0 }
        if relAz >  180.0 { relAz -= 360.0 }

        let xFraction = (relAz + 180.0) / 360.0
        let minX = spawnMinX + Double(radius)
        let maxX = spawnMaxX - Double(radius)
        let x = minX + xFraction * (maxX - minX)

        return CGPoint(x: x, y: y)
    }

    /// Returns a stable, day-seeded position used when `belowHorizonBehavior` is
    /// `"random"` (always) or `"randomWhenBelow"` (when below horizon).
    ///
    /// The position changes once per calendar day (UTC) so it does not drift
    /// during a screensaver session.
    private func deterministicOffHorizonPoint(now: Date) -> CGPoint {
        let dayIndex = Int(now.timeIntervalSince1970 / 86400.0)
        // Mix identity into seed so different planets get different positions.
        let identitySeed = UInt64(identity.rawValue.unicodeScalars.reduce(0) { $0 &+ UInt32($1.value) })
        let daySeed = UInt64(bitPattern: Int64(dayIndex) &* 2_654_435_761) &+ identitySeed
        var rng = SeededRNG(seed: daySeed ^ (nonce &* 6_364_136_223_846_793_005))

        let r   = Double(radius)
        let minX = spawnMinX + r
        let maxX = spawnMaxX - r
        let minY = spawnMinY + r
        let maxY = spawnMaxY - r
        let x = minX + rng.nextDouble() * (maxX - minX)
        let y = minY + rng.nextDouble() * (maxY - minY)

        return CGPoint(x: x, y: y)
    }

    // MARK: - Keplerian Ephemeris

    // J2000.0 Keplerian orbital elements for each planet.
    // Fields: (L0, L1, e0, e1, a, om0, om1, i0, i1)
    //   L0/L1  — mean longitude at J2000 (°) and rate (°/century)
    //   e0/e1  — eccentricity and rate
    //   a      — semi-major axis (AU, treated as constant)
    //   om0/om1— longitude of perihelion (°) and rate
    //   i0/i1  — inclination (°) and rate
    private struct OrbitalElements {
        let L0: Double, L1: Double
        let e0: Double, e1: Double
        let a:  Double
        let om0: Double, om1: Double
        let i0: Double,  i1: Double
    }

    private static func orbitalElements(for identity: PlanetIdentity) -> OrbitalElements {
        switch identity {
        case .mercury:
            return OrbitalElements(
                L0: 252.250324, L1: 149472.6746358,
                e0: 0.20563175, e1: 0.000020407,
                a:  0.38709893,
                om0: 77.456119, om1: 0.1588643,
                i0:  7.004986,  i1: -0.0059516
            )
        case .venus:
            return OrbitalElements(
                L0: 181.979801, L1: 58517.8156760,
                e0: 0.00677188, e1: -0.000047766,
                a:  0.72333199,
                om0: 131.563707, om1: 0.0048746,
                i0:  3.394662,   i1: -0.0008568
            )
        case .mars:
            return OrbitalElements(
                L0: 355.433275, L1: 19140.2993313,
                e0: 0.09340062, e1: 0.000090484,
                a:  1.52366231,
                om0: 336.060234, om1: 0.4439016,
                i0:   1.849726,  i1: -0.0081477
            )
        case .jupiter:
            return OrbitalElements(
                L0:  34.396441,  L1: 3034.9056746,
                e0:   0.04849793, e1: -0.000163225,
                a:    5.202603,
                om0: 14.753385,  om1:  0.1107672,
                i0:   1.303270,  i1:  -0.0019877
            )
        case .saturn:
            // Elements from user spec: a=9.5826, e=0.0565, i=2.4845°,
            // node(Ω)=113.665°, peri(ω)=339.392°, M0=317.020°, period=10759.22d.
            // Longitude of perihelion: ϖ = Ω + ω = 113.665 + 339.392 = 453.057 → 93.057°
            // Mean longitude at J2000: L0 = M0 + ϖ = 317.020 + 93.057 = 410.077 → 50.077°
            // L1 (°/century) = 360 × 36525 / 10759.22 ≈ 1222.11
            return OrbitalElements(
                L0:  50.077,     L1: 1222.1138488,
                e0:   0.0565,    e1: -0.000346641,
                a:    9.5826,
                om0:  93.057,   om1:  0.5664480,
                i0:   2.4845,    i1:  -0.0037363
            )
        case .uranus:
            return OrbitalElements(
                L0: 314.055005, L1: 429.8640561,
                e0: 0.04716771, e1: -0.000019150,
                a:  19.19126393,
                om0: 172.884833, om1: 0.0466418,
                i0:   0.769986,  i1:  0.0007615
            )
        case .neptune:
            return OrbitalElements(
                L0: 304.348665, L1: 218.4862002,
                e0: 0.00858587, e1: 0.000002510,
                a:  30.06896348,
                om0: 48.120276, om1: 0.0291866,
                i0:   1.769952, i1: -0.0093082
            )
        case .pluto:
            // Approximate; Pluto's orbit is significantly non-Keplerian over long timescales.
            return OrbitalElements(
                L0: 238.92881, L1: 145.2078,
                e0: 0.2488273,  e1: 0.00006,
                a:  39.48168677,
                om0: 224.06676, om1: 0.0,
                i0:  17.14175,  i1: 0.0
            )
        }
    }

    private static func earthOrbitalElements() -> OrbitalElements {
        return OrbitalElements(
            L0: 100.46435,
            L1: 35999.3729,
            e0: 0.01671,
            e1: 0.0,
            a: 1.00000,
            om0: 102.93768,
            om1: 0.0,
            i0: 0.00005,
            i1: 0.0
        )
    }

    private struct MoonOrbitDefinition {
        let name: String
        let periodDays: Double
        let semiMajorAxisPlanetRadii: Double
        let initialPhaseRad: Double
        let color: SIMD3<Float>
        let baseSizePx: Double
    }

    private static let moonOrbitDefinitions: [PlanetIdentity: [MoonOrbitDefinition]] = [
        .jupiter: [
            MoonOrbitDefinition(
                name: "Io",
                periodDays: 1.769138,
                semiMajorAxisPlanetRadii: 5.91,
                initialPhaseRad: toRad(106.1),
                color: SIMD3<Float>(1.0, 0.95, 0.6),
                baseSizePx: 2.0
            ),
            MoonOrbitDefinition(
                name: "Europa",
                periodDays: 3.551181,
                semiMajorAxisPlanetRadii: 9.40,
                initialPhaseRad: toRad(175.8),
                color: SIMD3<Float>(0.9, 0.9, 1.0),
                baseSizePx: 1.5
            ),
            MoonOrbitDefinition(
                name: "Ganymede",
                periodDays: 7.154553,
                semiMajorAxisPlanetRadii: 14.97,
                initialPhaseRad: toRad(121.0),
                color: SIMD3<Float>(0.85, 0.8, 0.7),
                baseSizePx: 2.5
            ),
            MoonOrbitDefinition(
                name: "Callisto",
                periodDays: 16.689018,
                semiMajorAxisPlanetRadii: 26.33,
                initialPhaseRad: toRad(85.0),
                color: SIMD3<Float>(0.5, 0.5, 0.5),
                baseSizePx: 2.0
            ),
        ],
        .saturn: [
            MoonOrbitDefinition(
                name: "Titan",
                periodDays: 15.945421,
                semiMajorAxisPlanetRadii: 20.27,
                initialPhaseRad: toRad(15.0),
                color: SIMD3<Float>(0.9, 0.7, 0.3),
                baseSizePx: 2.0
            )
        ],
    ]

    private static let j2000MoonEpochUTC = Date(timeIntervalSince1970: 947678400)

    /// Computes altitude and azimuth (degrees) for any planet at the Austin TX
    /// observer location for the supplied date.
    ///
    /// Accuracy: ~1° for dates within a few decades of J2000.0.
    static func horizontalCoordinates(for identity: PlanetIdentity, now: Date)
        -> (altitudeDeg: Double, azimuthDeg: Double)
    {
        let T = julianCentury(from: now)
        let (planetLon, planetLat, planetR) = heliocentricEcliptic(for: identity, T: T)
        let (earthLon, earthLat, earthR) = earthHeliocentricEcliptic(T: T)

        let planetHelio = heliocentricCartesian(lonDeg: planetLon, latDeg: planetLat, radiusAU: planetR)
        let earthHelio = heliocentricCartesian(lonDeg: earthLon, latDeg: earthLat, radiusAU: earthR)

        let dx = planetHelio.x - earthHelio.x
        let dy = planetHelio.y - earthHelio.y
        let dz = planetHelio.z - earthHelio.z

        // Rotate ecliptic → equatorial (J2000 obliquity).
        let eps    = toRad(23.4392911)
        let xEq    = dx
        let yEq    = cos(eps) * dy - sin(eps) * dz
        let zEq    = sin(eps) * dy + cos(eps) * dz

        // RA / Dec.
        let ra     = atan2(yEq, xEq)   // radians
        let dist   = sqrt(dx*dx + dy*dy + dz*dz)
        let dec    = asin(zEq / dist)   // radians

        // Local Sidereal Time for Austin TX.
        let lst    = localSiderealTime(jd: julianDay(from: now), lonDeg: observerLonDeg)

        // Hour Angle.
        let ha     = lst - ra   // radians

        // Horizontal coordinates.
        let latRad = toRad(observerLatDeg)
        let sinAlt = sin(dec) * sin(latRad) + cos(dec) * cos(latRad) * cos(ha)
        let altRad = asin(sinAlt)

        let cosAz  = (sin(dec) - sin(altRad) * sin(latRad)) / (cos(altRad) * cos(latRad))
        let cosAzC = min(max(cosAz, -1.0), 1.0)
        var azRad  = acos(cosAzC)
        if sin(ha) > 0 { azRad = 2.0 * Double.pi - azRad }  // north-through-east convention

        return (toDeg(altRad), toDeg(azRad))
    }

    /// Thin wrapper for backward compatibility with any remaining callers.
    static func jupiterHorizontal(now: Date) -> (altitudeDeg: Double, azimuthDeg: Double) {
        return horizontalCoordinates(for: .jupiter, now: now)
    }

    // MARK: - Orbital Element Propagation

    private static func geocentricEcliptic(for identity: PlanetIdentity, now: Date) -> (lonDeg: Double, latDeg: Double) {
        let T = julianCentury(from: now)
        let (planetLon, planetLat, planetR) = heliocentricEcliptic(for: identity, T: T)
        let (earthLon, earthLat, earthR) = earthHeliocentricEcliptic(T: T)

        let planetHelio = heliocentricCartesian(lonDeg: planetLon, latDeg: planetLat, radiusAU: planetR)
        let earthHelio = heliocentricCartesian(lonDeg: earthLon, latDeg: earthLat, radiusAU: earthR)

        let dx = planetHelio.x - earthHelio.x
        let dy = planetHelio.y - earthHelio.y
        let dz = planetHelio.z - earthHelio.z

        let geoLon = normalise(toDeg(atan2(dy, dx)))
        let dist   = sqrt(dx*dx + dy*dy + dz*dz)
        let geoLat = toDeg(asin(dz / dist))

        return (geoLon, geoLat)
    }

    private static func phaseState(for identity: PlanetIdentity, now: Date) -> (fraction: Double, waxingSign: Double) {
        let T = julianCentury(from: now)
        let (planetLon, planetLat, planetR) = heliocentricEcliptic(for: identity, T: T)
        let (earthLon, earthLat, earthR) = earthHeliocentricEcliptic(T: T)

        let planetHelio = heliocentricCartesian(lonDeg: planetLon, latDeg: planetLat, radiusAU: planetR)
        let earthHelio = heliocentricCartesian(lonDeg: earthLon, latDeg: earthLat, radiusAU: earthR)

        let earthToPlanetX = planetHelio.x - earthHelio.x
        let earthToPlanetY = planetHelio.y - earthHelio.y
        let earthToPlanetZ = planetHelio.z - earthHelio.z

        let d = sqrt(earthToPlanetX * earthToPlanetX + earthToPlanetY * earthToPlanetY + earthToPlanetZ * earthToPlanetZ)
        let r = planetR
        let R = earthR
        if d < 1e-9 || r < 1e-9 || R < 1e-9 {
            return (1.0, 1.0)
        }

        let cosAlphaRaw = (r * r + d * d - R * R) / (2.0 * r * d)
        let cosAlpha = min(max(cosAlphaRaw, -1.0), 1.0)
        let fraction = 0.5 * (1.0 + cosAlpha)

        let crossZ = planetHelio.x * earthToPlanetY - planetHelio.y * earthToPlanetX
        let waxingSign = crossZ >= 0.0 ? 1.0 : -1.0

        return (min(max(fraction, 0.0), 1.0), waxingSign)
    }

    private static func heliocentricEcliptic(for identity: PlanetIdentity, T: Double) -> (lonDeg: Double, latDeg: Double, radiusAU: Double) {
        let elements = orbitalElements(for: identity)
        return heliocentricEcliptic(
            L0: elements.L0,
            L1: elements.L1,
            e0: elements.e0,
            e1: elements.e1,
            a: elements.a,
            om0: elements.om0,
            om1: elements.om1,
            i0: elements.i0,
            i1: elements.i1,
            T: T
        )
    }

    private static func earthHeliocentricEcliptic(T: Double) -> (lonDeg: Double, latDeg: Double, radiusAU: Double) {
        let elements = earthOrbitalElements()
        return heliocentricEcliptic(
            L0: elements.L0,
            L1: elements.L1,
            e0: elements.e0,
            e1: elements.e1,
            a: elements.a,
            om0: elements.om0,
            om1: elements.om1,
            i0: elements.i0,
            i1: elements.i1,
            T: T
        )
    }

    private static func heliocentricCartesian(lonDeg: Double, latDeg: Double, radiusAU: Double) -> (x: Double, y: Double, z: Double) {
        let lonR = toRad(lonDeg)
        let latR = toRad(latDeg)
        return (
            radiusAU * cos(latR) * cos(lonR),
            radiusAU * cos(latR) * sin(lonR),
            radiusAU * sin(latR)
        )
    }

    /// Saturn ring opening angle B (degrees) via simplified Schlyter formula.
    /// B = arcsin(sin(β)·cos(28.06°) − cos(β)·sin(28.06°)·sin(λ − Nr))
    /// where Nr = 169.51° + 3.82e-5°·d (d = days since J2000).
    private static func saturnRingTilt(geocentricLonDeg: Double, geocentricLatDeg: Double, daysSinceJ2000: Double) -> Double {
        let Nr      = toRad(normalise(169.51 + 3.82e-5 * daysSinceJ2000))
        let lambda  = toRad(geocentricLonDeg)
        let beta    = toRad(geocentricLatDeg)
        let tiltRad = toRad(28.06)
        let sinB    = sin(beta) * cos(tiltRad) - cos(beta) * sin(tiltRad) * sin(lambda - Nr)
        return toDeg(asin(max(-1.0, min(1.0, sinB))))
    }

    private static func saturnRingPositionAngle(saturnRARad: Double, saturnDecRad: Double) -> Double {
        let alphaPole = toRad(40.589)
        let deltaPole = toRad(83.537)
        let deltaAlpha = alphaPole - saturnRARad

        let numerator = cos(deltaPole) * sin(deltaAlpha)
        let denominator = sin(deltaPole) * cos(saturnDecRad)
            - cos(deltaPole) * sin(saturnDecRad) * cos(deltaAlpha)

        let p = atan2(numerator, denominator)
        return normaliseSigned(toDeg(p))
    }

    private static func geocentricEquatorialFromEcliptic(lonDeg: Double, latDeg: Double) -> (raRad: Double, decRad: Double) {
        let lambda = toRad(lonDeg)
        let beta = toRad(latDeg)
        let eps = toRad(23.4392911)

        let xEcl = cos(beta) * cos(lambda)
        let yEcl = cos(beta) * sin(lambda)
        let zEcl = sin(beta)

        let xEq = xEcl
        let yEq = cos(eps) * yEcl - sin(eps) * zEcl
        let zEq = sin(eps) * yEcl + cos(eps) * zEcl

        let ra = atan2(yEq, xEq)
        let dec = asin(max(-1.0, min(1.0, zEq)))
        return (ra, dec)
    }

    /// Returns (longitude°, latitude°, radius AU) in heliocentric ecliptic
    /// coordinates using simplified two-body Keplerian elements.
    private static func heliocentricEcliptic(
        L0:  Double, L1:  Double,   // mean longitude (°) and rate (°/century)
        e0:  Double, e1:  Double,   // eccentricity and rate
        a:   Double,                // semi-major axis (AU, treated as constant here)
        om0: Double, om1: Double,   // longitude of perihelion (°) and rate
        i0:  Double, i1:  Double,   // inclination (°) and rate
        T:   Double                 // Julian centuries from J2000
    ) -> (lonDeg: Double, latDeg: Double, radiusAU: Double) {
        let L  = normalise(L0  + L1  * T)   // mean longitude (°)
        let e  = e0  + e1  * T              // eccentricity
        let om = normalise(om0 + om1 * T)   // longitude of perihelion (°)
        let i  = i0  + i1  * T              // inclination (°)

        // Mean anomaly
        let M  = toRad(normalise(L - om))

        // Eccentric anomaly via Newton–Raphson (3 iterations are plenty)
        var E  = M
        for _ in 0..<4 {
            E -= (E - e * sin(E) - M) / (1.0 - e * cos(E))
        }

        // True anomaly
        let nu = 2.0 * atan2(
            sqrt(1.0 + e) * sin(E / 2.0),
            sqrt(1.0 - e) * cos(E / 2.0)
        )

        // Heliocentric distance
        let r = a * (1.0 - e * cos(E))

        // Ecliptic longitude & latitude (simplified: small-inclination approximation)
        let lonDeg = normalise(toDeg(nu) + om)
        let latDeg = toDeg(asin(sin(toRad(i)) * sin(toRad(lonDeg - om))))

        return (lonDeg, latDeg, r)
    }

    // MARK: - Time Helpers

    private static func julianDay(from date: Date) -> Double {
        return 2440587.5 + date.timeIntervalSince1970 / 86400.0
    }

    private static func julianCentury(from date: Date) -> Double {
        return (julianDay(from: date) - 2451545.0) / 36525.0
    }

    /// Greenwich Mean Sidereal Time in radians, then shifted by observer longitude.
    private static func localSiderealTime(jd: Double, lonDeg: Double) -> Double {
        // GMST in degrees (IAU 1982)
        let D    = jd - 2451545.0
        let gmst = 280.46061837 + 360.98564736629 * D
        let lst  = normalise(gmst + lonDeg)   // east longitude is positive
        return toRad(lst)
    }

    // MARK: - Angle Utilities

    private static func toRad(_ deg: Double) -> Double { deg * Double.pi / 180.0 }
    private static func toDeg(_ rad: Double) -> Double { rad * 180.0 / Double.pi }

    /// Normalise angle to [0, 360).
    private static func normalise(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360.0)
        if d < 0 { d += 360.0 }
        return d
    }

    private static func normaliseSigned(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360.0)
        if d >= 180.0 { d -= 360.0 }
        if d < -180.0 { d += 360.0 }
        return d
    }
}

// MARK: - Minimal deterministic RNG (xorshift64)

/// A tiny, self-contained pseudo-random number generator used only for
/// day-seeded off-horizon positions. Not suitable for cryptographic use.
private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Returns a Double in [0, 1).
    mutating func nextDouble() -> Double {
        return Double(next() >> 11) / Double(1 << 53)
    }
}
