//! Solar-system planet positioning, phase, and per-frame state.
//!
//! Ported from `StarryExcuseForAMacScreensaver/Planet.swift`. Phase 5a Step 1
//! covered the simulation surface: identity, Keplerian ephemeris, alt/az from a
//! hardcoded Austin TX observer, screen mapping, per-day deterministic
//! off-horizon fallback, and the `PlanetParams` engine-side struct that later
//! feeds the GPU UBO. Texture generation, shader, and the `PlanetRenderer` GPU
//! pipeline live in sibling modules.
//!
//! Phase 5b adds Saturn-specific ring math: `saturn_ring_state` computes the
//! ring tilt B (simplified Schlyter) and position angle (celestial-pole
//! formula) for the current wall-clock time, and `frame_state` routes those
//! into `PlanetFrameState` for Saturn only. The Galilean / Titan moon-dot
//! ephemerides land in Phase 5c.
//!
//! ## Astronomy pipeline (per frame)
//! 1. Look up J2000.0 Keplerian elements for the requested planet.
//! 2. Propagate to the requested wall-clock date → heliocentric ecliptic.
//! 3. Subtract Earth's heliocentric position → geocentric vector.
//! 4. Rotate ecliptic → equatorial (J2000 obliquity 23.4393°).
//! 5. Compute Hour Angle from GMST + observer longitude → local alt/az.
//! 6. Map alt/az onto the shooting-star spawn box (origin bottom-left).
//!
//! ## Below-horizon behaviour
//! - `Hide` → brightness 0.0, centre off-screen.
//! - `Random` → always uses the deterministic per-day position (orbital position is ignored even when above horizon).
//! - `RandomWhenBelow` → orbital position when above horizon, deterministic per-day position when below.
//!
//! The "deterministic per-day" position is xorshift64-seeded from
//! `(day_index, planet_identity, engine_nonce)`, so it's stable for the whole
//! UTC day and the whole engine lifetime, but reshuffles across engine
//! recreations (matching Swift's "Regenerate Preview" behaviour).

use std::time::{SystemTime, UNIX_EPOCH};

use crate::types::Color;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Austin, TX latitude (degrees, north positive). Matches Swift.
const OBSERVER_LAT_DEG: f64 = 30.2672;
/// Austin, TX longitude (degrees, east positive).
const OBSERVER_LON_DEG: f64 = -97.7431;

/// Julian Day of J2000.0 epoch (2000-01-01 12:00 TT).
const J2000_JD: f64 = 2_451_545.0;
/// Julian Day of the Unix epoch (1970-01-01 00:00 UT).
const UNIX_EPOCH_AS_JD: f64 = 2_440_587.5;
/// J2000.0 mean obliquity of the ecliptic (degrees).
const J2000_OBLIQUITY_DEG: f64 = 23.439_291_1;

/// Knuth multiplicative hash constant — mixed into the day seed so adjacent
/// days produce uncorrelated positions.
const KNUTH_MULT: u64 = 2_654_435_761;
/// LCG multiplier (SplitMix64) — mixes the engine nonce into the seed so
/// distinct engine instances on the same calendar day produce different
/// off-horizon positions.
const SPLITMIX_LCG: u64 = 6_364_136_223_846_793_005;

// ---------------------------------------------------------------------------
// PlanetIdentity
// ---------------------------------------------------------------------------

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash)]
pub enum PlanetIdentity {
    Mercury,
    Venus,
    Mars,
    Jupiter,
    Saturn,
    Uranus,
    Neptune,
    Pluto,
}

impl PlanetIdentity {
    /// Lowercase identity string, matching Swift's `rawValue` and the HashMap
    /// keys used by the engine.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Mercury => "mercury",
            Self::Venus => "venus",
            Self::Mars => "mars",
            Self::Jupiter => "jupiter",
            Self::Saturn => "saturn",
            Self::Uranus => "uranus",
            Self::Neptune => "neptune",
            Self::Pluto => "pluto",
        }
    }

    /// All planets in a stable enumeration order. `for id in PlanetIdentity::ALL`
    /// mirrors Swift's `PlanetIdentity.allCases`.
    pub const ALL: [PlanetIdentity; 8] = [
        Self::Mercury,
        Self::Venus,
        Self::Mars,
        Self::Jupiter,
        Self::Saturn,
        Self::Uranus,
        Self::Neptune,
        Self::Pluto,
    ];
}

// ---------------------------------------------------------------------------
// BelowHorizonBehavior
// ---------------------------------------------------------------------------

#[derive(Copy, Clone, Debug, PartialEq, Eq, clap::ValueEnum, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum BelowHorizonBehavior {
    /// Planet is hidden (brightness 0.0) whenever it is geometrically below the
    /// horizon for the observer.
    Hide,
    /// Planet ALWAYS uses the deterministic per-day off-horizon position,
    /// regardless of whether it is above or below the actual horizon.
    Random,
    /// Planet uses its real orbital position when above horizon, and the
    /// deterministic per-day position when below.
    RandomWhenBelow,
}

impl BelowHorizonBehavior {
    /// Parse the config string. Unrecognised values fall back to
    /// `RandomWhenBelow` so configuration typos can't disable a planet
    /// entirely. Kept as a convenience for non-clap callers (e.g. future
    /// settings-file readers); CLI parsing goes through the `ValueEnum`
    /// derive above.
    pub fn from_config_str(s: &str) -> Self {
        match s {
            "hide" => Self::Hide,
            "random" => Self::Random,
            _ => Self::RandomWhenBelow,
        }
    }
}

/// `Display` delegates to clap's own `ValueEnum` name mapping so the
/// `default_value_t = ...` attribute in [`crate::config::Config`] produces
/// exactly the same string clap will accept back on the command line.
/// Single source of truth — no risk of default/parser drift.
impl std::fmt::Display for BelowHorizonBehavior {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        use clap::ValueEnum;
        self.to_possible_value()
            .expect("BelowHorizonBehavior variants are not #[value(skip)]")
            .get_name()
            .fmt(f)
    }
}

// ---------------------------------------------------------------------------
// Per-frame state
// ---------------------------------------------------------------------------

#[derive(Copy, Clone, Debug)]
pub struct PlanetFrameState {
    /// Screen position in pixels, origin bottom-left (same convention as the
    /// rest of the simulation).
    pub center_px: (f64, f64),
    /// 0.0 when the planet should not render, otherwise 1.0. (Brightness is
    /// always a hard on/off; the shader handles dimming via the dark
    /// hemisphere brightness uniform.)
    pub brightness: f32,
    /// True when the planet is geometrically above the horizon for the
    /// hardcoded Austin observer at this wall-clock time. False during
    /// off-horizon fallback (whether shown via Random / RandomWhenBelow or
    /// hidden via Hide).
    pub above_horizon: bool,
    /// Sun-illuminated fraction of the planet's disc, 0=new through 1=full.
    pub phase_fraction: f64,
    /// +1.0 for waxing (lit limb on right), -1.0 for waning. Matches the moon
    /// shader's sign convention.
    pub waxing_sign: f64,
    /// Saturn ring opening angle B in degrees (-27° to +27°). 0.0 for all
    /// non-Saturn planets and for Saturn in Phase 5a (ring math lands in 5b).
    pub ring_tilt_deg: f64,
    /// Saturn ring position angle in degrees. 0.0 for all non-Saturn planets
    /// and for Saturn in Phase 5a.
    pub ring_rotation_deg: f64,
}

// ---------------------------------------------------------------------------
// PlanetParams — engine-side struct mirroring Swift's MetalTypes.PlanetParams.
// Packing into the GPU UBO happens in planet_renderer.rs (Phase 5a Step 4).
// ---------------------------------------------------------------------------

#[derive(Copy, Clone, Debug)]
pub struct PlanetParams {
    pub center_px: [f32; 2],
    pub radius_px: f32,
    pub phase_fraction: f32,
    pub bright_brightness: f32,
    pub dark_brightness: f32,
    pub waxing_sign: f32,
    pub terminator_mode: i32, // 0=hard, 1=smooth, 2=banded
    pub terminator_width: f32,
    pub terminator_bands: i32,
    /// 1.0 for round-disc planets, 2.0 for Saturn (wide quad covers ring
    /// extent). The engine sets 2.0 only for Saturn; everything else gets
    /// 1.0 and skips the ring-bearing code path in the shader.
    pub texture_aspect: f32,
    pub ring_tilt_deg: f32,
    pub ring_rotation_deg: f32,
    pub ring_style: i32, // 0=Smooth, 1=Flat Retro, 2=Chunky Pixel
}

// ---------------------------------------------------------------------------
// Planet — per-instance state owned by Engine
// ---------------------------------------------------------------------------

pub struct Planet {
    pub identity: PlanetIdentity,
    pub screen_width: i32,
    pub screen_height: i32,
    pub radius: i32,

    below_horizon_behavior: BelowHorizonBehavior,
    nonce: u64,

    // Spawn box (pixels from bottom-left). Mirrors the rectangle used by
    // ShootingStarsLayerRenderer so planets never overlap building silhouettes.
    spawn_min_x: f64,
    spawn_max_x: f64,
    spawn_min_y: f64,
    spawn_max_y: f64,
}

impl Planet {
    pub fn new(
        identity: PlanetIdentity,
        screen_width: i32,
        screen_height: i32,
        building_max_height: i32,
        radius: i32,
        below_horizon_behavior: BelowHorizonBehavior,
        nonce: u64,
    ) -> Self {
        // Spawn box mirrors ShootingStarsLayerRenderer (Swift Planet.swift:94-100).
        let spawn_margin: i32 = 4;
        let safe_min_y = building_max_height + spawn_margin;
        Self {
            identity,
            screen_width,
            screen_height,
            radius: radius.max(1),
            below_horizon_behavior,
            nonce,
            spawn_min_x: spawn_margin as f64,
            spawn_max_x: (screen_width - spawn_margin) as f64,
            spawn_min_y: (safe_min_y + spawn_margin + 8) as f64,
            spawn_max_y: (screen_height - spawn_margin) as f64,
        }
    }

    /// Per-frame display state. Pure function of `(self, now)`.
    pub fn frame_state(&self, now: SystemTime) -> PlanetFrameState {
        let (alt_deg, az_deg) = horizontal_coordinates(self.identity, now);
        let above_horizon = alt_deg > 0.0;
        let (phase_fraction, waxing_sign) = phase_state(self.identity, now);

        let (ring_tilt_deg, ring_rotation_deg) = if self.identity == PlanetIdentity::Saturn {
            saturn_ring_state(now)
        } else {
            (0.0, 0.0)
        };

        // "Random" mode short-circuits orbital position entirely.
        if self.below_horizon_behavior == BelowHorizonBehavior::Random {
            let center_px = self.deterministic_off_horizon_point(now);
            return PlanetFrameState {
                center_px,
                brightness: 1.0,
                above_horizon: false,
                phase_fraction,
                waxing_sign,
                ring_tilt_deg,
                ring_rotation_deg,
            };
        }

        if above_horizon {
            let center_px = self.screen_point(alt_deg, az_deg);
            return PlanetFrameState {
                center_px,
                brightness: 1.0,
                above_horizon: true,
                phase_fraction,
                waxing_sign,
                ring_tilt_deg,
                ring_rotation_deg,
            };
        }

        // Below horizon — branch on behaviour.
        match self.below_horizon_behavior {
            BelowHorizonBehavior::RandomWhenBelow => {
                let center_px = self.deterministic_off_horizon_point(now);
                PlanetFrameState {
                    center_px,
                    brightness: 1.0,
                    above_horizon: false,
                    phase_fraction,
                    waxing_sign,
                    ring_tilt_deg,
                    ring_rotation_deg,
                }
            }
            // Hide (and BelowHorizonBehavior::Random, which already returned above).
            _ => {
                let off = -(self.radius as f64) * 2.0;
                PlanetFrameState {
                    center_px: (off, off),
                    brightness: 0.0,
                    above_horizon: false,
                    phase_fraction,
                    waxing_sign,
                    ring_tilt_deg,
                    ring_rotation_deg,
                }
            }
        }
    }

    /// Maps altitude [0°, 90°] and azimuth [0°, 360°] onto the spawn box.
    ///
    /// Vertical: altitude 0° → spawn_min_y + radius, altitude 90° → spawn_max_y - radius.
    /// Horizontal: south (180°) → spawn box centre; all edges inset by radius.
    fn screen_point(&self, altitude_deg: f64, azimuth_deg: f64) -> (f64, f64) {
        let alt_clamped = altitude_deg.clamp(0.0, 90.0);
        let alt_fraction = alt_clamped / 90.0;

        let r = self.radius as f64;
        let bottom_y = self.spawn_min_y + r;
        let top_y = self.spawn_max_y - r;
        let y = bottom_y + alt_fraction * (top_y - bottom_y);

        let mut rel_az = azimuth_deg - 180.0;
        if rel_az < -180.0 {
            rel_az += 360.0;
        }
        if rel_az > 180.0 {
            rel_az -= 360.0;
        }
        let x_fraction = (rel_az + 180.0) / 360.0;
        let min_x = self.spawn_min_x + r;
        let max_x = self.spawn_max_x - r;
        let x = min_x + x_fraction * (max_x - min_x);

        (x, y)
    }

    /// Day-seeded, identity-mixed, nonce-shuffled position. Stable for the
    /// duration of a UTC day and a single engine instance.
    fn deterministic_off_horizon_point(&self, now: SystemTime) -> (f64, f64) {
        let unix_secs = now
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        let day_index = (unix_secs / 86_400.0).floor() as i64;

        let identity_seed = identity_string_seed(self.identity.name());
        let day_seed = (day_index as u64)
            .wrapping_mul(KNUTH_MULT)
            .wrapping_add(identity_seed);
        let rng_seed = day_seed ^ self.nonce.wrapping_mul(SPLITMIX_LCG);

        let mut rng = SeededRng::new(rng_seed);

        let r = self.radius as f64;
        let min_x = self.spawn_min_x + r;
        let max_x = self.spawn_max_x - r;
        let min_y = self.spawn_min_y + r;
        let max_y = self.spawn_max_y - r;
        let x = min_x + rng.next_f64() * (max_x - min_x);
        let y = min_y + rng.next_f64() * (max_y - min_y);
        (x, y)
    }
}

// ---------------------------------------------------------------------------
// Orbital elements (J2000.0)
// ---------------------------------------------------------------------------

/// Simplified two-body Keplerian elements with linear rates.
/// Units: degrees and AU; rates are per Julian century from J2000.
#[derive(Copy, Clone, Debug)]
struct OrbitalElements {
    l0: f64,  // mean longitude (°)
    l1: f64,  // rate (°/century)
    e0: f64,  // eccentricity
    e1: f64,  // rate
    a: f64,   // semi-major axis (AU, treated as constant)
    om0: f64, // longitude of perihelion (°)
    om1: f64, // rate
    i0: f64,  // inclination (°)
    i1: f64,  // rate
}

fn orbital_elements(identity: PlanetIdentity) -> OrbitalElements {
    match identity {
        PlanetIdentity::Mercury => OrbitalElements {
            l0: 252.250324,
            l1: 149_472.674_635_8,
            e0: 0.205_631_75,
            e1: 0.000_020_407,
            a: 0.387_098_93,
            om0: 77.456_119,
            om1: 0.158_864_3,
            i0: 7.004_986,
            i1: -0.005_951_6,
        },
        PlanetIdentity::Venus => OrbitalElements {
            l0: 181.979_801,
            l1: 58_517.815_676_0,
            e0: 0.006_771_88,
            e1: -0.000_047_766,
            a: 0.723_331_99,
            om0: 131.563_707,
            om1: 0.004_874_6,
            i0: 3.394_662,
            i1: -0.000_856_8,
        },
        PlanetIdentity::Mars => OrbitalElements {
            l0: 355.433_275,
            l1: 19_140.299_331_3,
            e0: 0.093_400_62,
            e1: 0.000_090_484,
            a: 1.523_662_31,
            om0: 336.060_234,
            om1: 0.443_901_6,
            i0: 1.849_726,
            i1: -0.008_147_7,
        },
        PlanetIdentity::Jupiter => OrbitalElements {
            l0: 34.396_441,
            l1: 3_034.905_674_6,
            e0: 0.048_497_93,
            e1: -0.000_163_225,
            a: 5.202_603,
            om0: 14.753_385,
            om1: 0.110_767_2,
            i0: 1.303_270,
            i1: -0.001_987_7,
        },
        PlanetIdentity::Saturn => OrbitalElements {
            // Derived from a=9.5826, e=0.0565, i=2.4845°, Ω=113.665°,
            // ω=339.392°, M0=317.020°, period=10759.22d (Swift Planet.swift:343-354).
            l0: 50.077,
            l1: 1_222.11,
            e0: 0.0565,
            e1: -0.000_346_641,
            a: 9.5826,
            om0: 93.057,
            om1: 0.566_448_0,
            i0: 2.4845,
            i1: -0.003_736_3,
        },
        PlanetIdentity::Uranus => OrbitalElements {
            l0: 314.055_005,
            l1: 429.864_056_1,
            e0: 0.047_167_71,
            e1: -0.000_019_150,
            a: 19.191_263_93,
            om0: 172.884_833,
            om1: 0.046_641_8,
            i0: 0.769_986,
            i1: 0.000_761_5,
        },
        PlanetIdentity::Neptune => OrbitalElements {
            l0: 304.348_665,
            l1: 218.486_200_2,
            e0: 0.008_585_87,
            e1: 0.000_002_510,
            a: 30.068_963_48,
            om0: 48.120_276,
            om1: 0.029_186_6,
            i0: 1.769_952,
            i1: -0.009_308_2,
        },
        PlanetIdentity::Pluto => OrbitalElements {
            // Approximate; Pluto's orbit is significantly non-Keplerian over
            // long timescales.
            l0: 238.928_81,
            l1: 145.2078,
            e0: 0.248_827_3,
            e1: 0.000_06,
            a: 39.481_686_77,
            om0: 224.066_76,
            om1: 0.0,
            i0: 17.141_75,
            i1: 0.0,
        },
    }
}

fn earth_orbital_elements() -> OrbitalElements {
    OrbitalElements {
        l0: 100.464_35,
        l1: 35_999.372_9,
        e0: 0.01671,
        e1: 0.0,
        a: 1.00000,
        om0: 102.937_68,
        om1: 0.0,
        i0: 0.00005,
        i1: 0.0,
    }
}

// ---------------------------------------------------------------------------
// Ephemeris math
// ---------------------------------------------------------------------------

/// Convert the planet's orbital state at `now` into local horizontal
/// coordinates for the Austin TX observer.
fn horizontal_coordinates(identity: PlanetIdentity, now: SystemTime) -> (f64, f64) {
    let t = julian_century(now);
    let (planet_lon, planet_lat, planet_r) = heliocentric_ecliptic(orbital_elements(identity), t);
    let (earth_lon, earth_lat, earth_r) = heliocentric_ecliptic(earth_orbital_elements(), t);

    let (px, py, pz) = heliocentric_cartesian(planet_lon, planet_lat, planet_r);
    let (ex, ey, ez) = heliocentric_cartesian(earth_lon, earth_lat, earth_r);

    let dx = px - ex;
    let dy = py - ey;
    let dz = pz - ez;

    // Rotate ecliptic → equatorial (J2000 obliquity).
    let eps = J2000_OBLIQUITY_DEG.to_radians();
    let x_eq = dx;
    let y_eq = eps.cos() * dy - eps.sin() * dz;
    let z_eq = eps.sin() * dy + eps.cos() * dz;

    // RA / Dec.
    let ra = y_eq.atan2(x_eq);
    let dist = (dx * dx + dy * dy + dz * dz).sqrt();
    let dec = (z_eq / dist).asin();

    // Local Sidereal Time for Austin TX.
    let lst = local_sidereal_time_rad(julian_day(now), OBSERVER_LON_DEG);

    // Hour Angle.
    let ha = lst - ra;

    // Horizontal coordinates.
    let lat_rad = OBSERVER_LAT_DEG.to_radians();
    let sin_alt = dec.sin() * lat_rad.sin() + dec.cos() * lat_rad.cos() * ha.cos();
    let alt_rad = sin_alt.asin();

    let cos_az = (dec.sin() - alt_rad.sin() * lat_rad.sin()) / (alt_rad.cos() * lat_rad.cos());
    let cos_az_clamped = cos_az.clamp(-1.0, 1.0);
    let mut az_rad = cos_az_clamped.acos();
    if ha.sin() > 0.0 {
        az_rad = 2.0 * std::f64::consts::PI - az_rad; // north-through-east
    }

    (alt_rad.to_degrees(), az_rad.to_degrees())
}

/// Sun-Earth-planet phase: returns (illuminated fraction, waxing sign).
fn phase_state(identity: PlanetIdentity, now: SystemTime) -> (f64, f64) {
    let t = julian_century(now);
    let (planet_lon, planet_lat, planet_r) = heliocentric_ecliptic(orbital_elements(identity), t);
    let (earth_lon, earth_lat, earth_r) = heliocentric_ecliptic(earth_orbital_elements(), t);

    let (px, py, pz) = heliocentric_cartesian(planet_lon, planet_lat, planet_r);
    let (ex, ey, ez) = heliocentric_cartesian(earth_lon, earth_lat, earth_r);

    let etpx = px - ex;
    let etpy = py - ey;
    let etpz = pz - ez;

    let d = (etpx * etpx + etpy * etpy + etpz * etpz).sqrt();
    let r = planet_r;
    let r_earth = earth_r;

    if d < 1e-9 || r < 1e-9 || r_earth < 1e-9 {
        return (1.0, 1.0);
    }

    let cos_alpha_raw = (r * r + d * d - r_earth * r_earth) / (2.0 * r * d);
    let cos_alpha = cos_alpha_raw.clamp(-1.0, 1.0);
    let fraction = 0.5 * (1.0 + cos_alpha);

    let cross_z = px * etpy - py * etpx;
    let waxing_sign = if cross_z >= 0.0 { 1.0 } else { -1.0 };

    (fraction.clamp(0.0, 1.0), waxing_sign)
}

/// Saturn ring tilt + position-angle in degrees, computed from the current
/// wall-clock time. Returns `(tilt_deg, position_angle_deg)`. Tilt comes
/// from the simplified Schlyter formula
/// `B = arcsin(sin β · cos 28.06° − cos β · sin 28.06° · sin(λ − Nr))`
/// where `Nr = 169.51° + 3.82e-5° · d` and `d` is days since J2000;
/// position angle from the celestial-pole formula
/// `p = atan2(cos δp · sin Δα, sin δp · cos δ − cos δp · sin δ · cos Δα)`
/// with `αp = 40.589°, δp = 83.537°`. Mirrors Swift `Planet.swift:603-622`.
fn saturn_ring_state(now: SystemTime) -> (f64, f64) {
    let t = julian_century(now);
    let (planet_lon, planet_lat, planet_r) =
        heliocentric_ecliptic(orbital_elements(PlanetIdentity::Saturn), t);
    let (earth_lon, earth_lat, earth_r) = heliocentric_ecliptic(earth_orbital_elements(), t);

    let (px, py, pz) = heliocentric_cartesian(planet_lon, planet_lat, planet_r);
    let (ex, ey, ez) = heliocentric_cartesian(earth_lon, earth_lat, earth_r);

    let dx = px - ex;
    let dy = py - ey;
    let dz = pz - ez;

    let geo_dist = (dx * dx + dy * dy + dz * dz).sqrt();
    if geo_dist < 1e-12 {
        return (0.0, 0.0);
    }

    let geo_lon_deg = dy.atan2(dx).to_degrees();
    let geo_lat_deg = (dz / geo_dist).asin().to_degrees();

    let days_since_j2000 = julian_day(now) - J2000_JD;
    let nr_rad = normalise(169.51 + 3.82e-5 * days_since_j2000).to_radians();
    let lambda = geo_lon_deg.to_radians();
    let beta = geo_lat_deg.to_radians();
    let saturn_axial_tilt = (28.06_f64).to_radians();
    let sin_b = beta.sin() * saturn_axial_tilt.cos()
        - beta.cos() * saturn_axial_tilt.sin() * (lambda - nr_rad).sin();
    let tilt_deg = sin_b.clamp(-1.0, 1.0).asin().to_degrees();

    let eps = J2000_OBLIQUITY_DEG.to_radians();
    let x_eq = dx;
    let y_eq = eps.cos() * dy - eps.sin() * dz;
    let z_eq = eps.sin() * dy + eps.cos() * dz;
    let ra_rad = y_eq.atan2(x_eq);
    let dec_rad = (z_eq / geo_dist).clamp(-1.0, 1.0).asin();

    let alpha_pole = (40.589_f64).to_radians();
    let delta_pole = (83.537_f64).to_radians();
    let delta_alpha = alpha_pole - ra_rad;
    let numerator = delta_pole.cos() * delta_alpha.sin();
    let denominator =
        delta_pole.sin() * dec_rad.cos() - delta_pole.cos() * dec_rad.sin() * delta_alpha.cos();
    let pa_deg = normalise_signed(numerator.atan2(denominator).to_degrees());

    (tilt_deg, pa_deg)
}

/// Heliocentric ecliptic coordinates (longitude°, latitude°, radius AU) from
/// orbital elements propagated to Julian century `t`.
fn heliocentric_ecliptic(elements: OrbitalElements, t: f64) -> (f64, f64, f64) {
    let l = normalise(elements.l0 + elements.l1 * t);
    let e = elements.e0 + elements.e1 * t;
    let om = normalise(elements.om0 + elements.om1 * t);
    let i = elements.i0 + elements.i1 * t;

    // Mean anomaly.
    let m = normalise(l - om).to_radians();

    // Eccentric anomaly via Newton-Raphson (4 iterations).
    let mut ecc = m;
    for _ in 0..4 {
        ecc -= (ecc - e * ecc.sin() - m) / (1.0 - e * ecc.cos());
    }

    // True anomaly.
    let nu =
        2.0 * ((1.0 + e).sqrt() * (ecc / 2.0).sin()).atan2((1.0 - e).sqrt() * (ecc / 2.0).cos());

    // Heliocentric distance.
    let r = elements.a * (1.0 - e * ecc.cos());

    // Ecliptic longitude & latitude (small-inclination approximation).
    let lon_deg = normalise(nu.to_degrees() + om);
    let lat_deg = (i.to_radians().sin() * (lon_deg - om).to_radians().sin())
        .asin()
        .to_degrees();

    (lon_deg, lat_deg, r)
}

fn heliocentric_cartesian(lon_deg: f64, lat_deg: f64, r_au: f64) -> (f64, f64, f64) {
    let lon_r = lon_deg.to_radians();
    let lat_r = lat_deg.to_radians();
    (
        r_au * lat_r.cos() * lon_r.cos(),
        r_au * lat_r.cos() * lon_r.sin(),
        r_au * lat_r.sin(),
    )
}

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------

/// Julian Day Number for the given wall-clock instant.
fn julian_day(now: SystemTime) -> f64 {
    let secs = now
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    UNIX_EPOCH_AS_JD + secs / 86_400.0
}

/// Julian centuries since J2000.0.
fn julian_century(now: SystemTime) -> f64 {
    (julian_day(now) - J2000_JD) / 36_525.0
}

/// Local Sidereal Time in radians for the given Julian Day and east longitude
/// in degrees. Uses GMST per IAU 1982.
fn local_sidereal_time_rad(jd: f64, lon_deg: f64) -> f64 {
    let d = jd - J2000_JD;
    let gmst = 280.460_618_37 + 360.985_647_366_29 * d;
    normalise(gmst + lon_deg).to_radians()
}

// ---------------------------------------------------------------------------
// Angle utilities
// ---------------------------------------------------------------------------

/// Normalise an angle in degrees to the half-open interval [0, 360).
fn normalise(deg: f64) -> f64 {
    let mut d = deg % 360.0;
    if d < 0.0 {
        d += 360.0;
    }
    d
}

/// Normalise an angle in degrees to the half-open interval [-180, 180).
/// Mirrors Swift `Planet.swift:714` (`normaliseSigned`); used only by the
/// Saturn ring position-angle path to wrap `atan2` output cleanly.
fn normalise_signed(deg: f64) -> f64 {
    let mut d = deg % 360.0;
    if d >= 180.0 {
        d -= 360.0;
    }
    if d < -180.0 {
        d += 360.0;
    }
    d
}

// ---------------------------------------------------------------------------
// Identity seed mixing
// ---------------------------------------------------------------------------

/// Sum the unicode scalar values of `name` with 32-bit wrap-add, widened to
/// u64. Matches Swift `Planet.swift:276`.
fn identity_string_seed(name: &str) -> u64 {
    let mut acc: u32 = 0;
    for c in name.chars() {
        acc = acc.wrapping_add(c as u32);
    }
    acc as u64
}

// ---------------------------------------------------------------------------
// Xorshift64 RNG (private; off-horizon positions only)
// ---------------------------------------------------------------------------

/// Tiny deterministic PRNG matching Swift's `SeededRNG` (Planet.swift:726-743)
/// for parity. Not for cryptographic use.
struct SeededRng {
    state: u64,
}

impl SeededRng {
    fn new(seed: u64) -> Self {
        Self {
            state: if seed == 0 { 1 } else { seed },
        }
    }

    fn next(&mut self) -> u64 {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        self.state
    }

    /// Returns an f64 in [0.0, 1.0).
    fn next_f64(&mut self) -> f64 {
        (self.next() >> 11) as f64 / ((1u64 << 53) as f64)
    }
}

// ---------------------------------------------------------------------------
// Moon sprite states (Galilean / Titan)
// ---------------------------------------------------------------------------
//
// Per-frame screen positions for the small bright dots representing Jupiter's
// four Galilean moons (Io / Europa / Ganymede / Callisto) and Saturn's
// largest moon (Titan). All other planets emit no moon sprites.
//
// The orbit math is intentionally simple — circular orbits in the planet's
// equatorial plane (Jupiter axial tilt approximated as 3°, Saturn matches the
// already-computed ring tilt). Foreshortening + ring-aligned rotation makes
// the dots appear to swing in a plane consistent with the planet's body.
// Mirrors Swift `Planet.swift:179-240` (`moonSpriteStates`) and Swift
// `Planet.swift:397-451` (`MoonOrbitDefinition` + `moonOrbitDefinitions`).

/// Anchor epoch for the Galilean / Titan orbital phase math:
/// 2000-01-12 00:00:00 UTC (`947_678_400` seconds since the Unix epoch).
/// Distinct from the lunar new-moon epoch in `moon.rs` — that one anchors
/// lunar-phase math, this one anchors planet-moon orbital phases. Mirrors
/// Swift `Planet.swift:453` (`Date(timeIntervalSince1970: 947678400)`).
const J2000_MOON_EPOCH_UNIX_SECS: f64 = 947_678_400.0;

/// Per-moon orbital + visual definition. Mirrors Swift `Planet.swift:397-404`.
/// Private — the orbit table is consumed only via [`moon_sprite_states`].
struct MoonOrbitDefinition {
    /// Lowercase ASCII identifier used for debug-color routing in
    /// [`crate::types`] and rendering bookkeeping in [`crate::engine`].
    name: &'static str,
    /// Sidereal orbital period in days.
    period_days: f64,
    /// Semi-major axis expressed as a multiple of the parent planet's body
    /// radius. The screen mapping multiplies by the parent's per-frame
    /// `parent_radius_px` to produce final screen offsets.
    semi_major_axis_planet_radii: f64,
    /// Phase offset at [`J2000_MOON_EPOCH_UNIX_SECS`] (radians).
    initial_phase_rad: f64,
    /// Linear (non-premultiplied) RGB tint of the moon dot.
    color: Color,
    /// Reference sprite size in pixels at the parent's "standard" radius
    /// (Jupiter 24 px, Saturn 20.3 px). Scaled per-frame by the parent's
    /// actual radius and clamped to `[1, 3]` after multiplier application.
    base_size_px: f64,
}

/// Galilean moons of Jupiter, in increasing orbital radius. Mirrors Swift
/// `Planet.swift:407-440`. The `initial_phase_rad` values reproduce Swift's
/// `toRad(<degrees>)` literals at compile time.
const JUPITER_MOONS: &[MoonOrbitDefinition] = &[
    MoonOrbitDefinition {
        name: "io",
        period_days: 1.769138,
        semi_major_axis_planet_radii: 5.91,
        initial_phase_rad: 106.1 * std::f64::consts::PI / 180.0,
        color: Color::new(1.0, 0.95, 0.6),
        base_size_px: 2.0,
    },
    MoonOrbitDefinition {
        name: "europa",
        period_days: 3.551181,
        semi_major_axis_planet_radii: 9.40,
        initial_phase_rad: 175.8 * std::f64::consts::PI / 180.0,
        color: Color::new(0.9, 0.9, 1.0),
        base_size_px: 1.5,
    },
    MoonOrbitDefinition {
        name: "ganymede",
        period_days: 7.154553,
        semi_major_axis_planet_radii: 14.97,
        initial_phase_rad: 121.0 * std::f64::consts::PI / 180.0,
        color: Color::new(0.85, 0.8, 0.7),
        base_size_px: 2.5,
    },
    MoonOrbitDefinition {
        name: "callisto",
        period_days: 16.689018,
        semi_major_axis_planet_radii: 26.33,
        initial_phase_rad: 85.0 * std::f64::consts::PI / 180.0,
        color: Color::new(0.5, 0.5, 0.5),
        base_size_px: 2.0,
    },
];

/// Saturn's only modelled moon, Titan. Mirrors Swift `Planet.swift:441-450`.
const SATURN_MOONS: &[MoonOrbitDefinition] = &[MoonOrbitDefinition {
    name: "titan",
    period_days: 15.945421,
    semi_major_axis_planet_radii: 20.27,
    initial_phase_rad: 15.0 * std::f64::consts::PI / 180.0,
    color: Color::new(0.9, 0.7, 0.3),
    base_size_px: 2.0,
}];

/// Per-frame screen-space sprite for a single planet-moon dot. Mirrors Swift
/// `Planet.swift:38-44` (`MoonSpriteState`). Consumed by [`crate::engine`] to
/// build the additive sprite stream for the planet-moons GPU layer.
#[derive(Copy, Clone, Debug)]
pub struct MoonSpriteState {
    /// Lowercase moon name — keys into `debug_moon_color_premul()` in
    /// [`crate::types`] when the debug-colors flag is enabled.
    pub name: &'static str,
    /// Screen position in pixels, origin bottom-left (matches the rest of
    /// the simulation's coordinate convention).
    pub center_px: (f64, f64),
    /// Sprite diameter in pixels, clamped to `[1.0, 3.0]`.
    pub size_px: f32,
    /// Linear (non-premultiplied) RGB tint.
    pub color: Color,
    /// Constant alpha matching Swift's hardcoded `0.78`. The engine
    /// premultiplies by this when packing sprite instances.
    pub alpha: f32,
}

/// Compute per-frame screen-space positions of a planet's moon dots.
///
/// Returns an empty `Vec` for non-Jupiter / non-Saturn parents, when
/// `parent_radius_px ≤ 0`, or when the parent has no defined moons.
/// Z-culls moons whose unrotated `y > 0` AND whose screen distance to the
/// parent centre is less than `parent_radius_px` — this hides moons "behind"
/// the planet body rather than rendering them through it.
///
/// `moon_scale` multiplies each moon's `base_size_px` BEFORE the global
/// `[1, 3]` clamp, so values >1 enlarge the dots and <1 shrink them while
/// still respecting the visual cap. Pass `1.0` for byte-stable Swift parity.
///
/// Mirrors Swift
/// `Planet.moonSpriteStates(for:now:parentCenter:parentRadiusPx:ringTiltDeg:rotationDeg:)`
/// at `Planet.swift:179-240`.
pub fn moon_sprite_states(
    parent: PlanetIdentity,
    now: SystemTime,
    parent_center_px: (f64, f64),
    parent_radius_px: f64,
    ring_tilt_deg: f64,
    rotation_deg: f64,
    moon_scale: f64,
    mut push: impl FnMut(MoonSpriteState),
) {
    if parent_radius_px <= 0.0 {
        return;
    }
    let defs: &[MoonOrbitDefinition] = match parent {
        PlanetIdentity::Jupiter => JUPITER_MOONS,
        PlanetIdentity::Saturn => SATURN_MOONS,
        _ => return,
    };
    if defs.is_empty() {
        return;
    }

    let secs_since_epoch = now
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let days_since_epoch = (secs_since_epoch - J2000_MOON_EPOCH_UNIX_SECS) / 86_400.0;

    let base_reference_radius_px = if matches!(parent, PlanetIdentity::Jupiter) {
        24.0
    } else {
        20.3
    };
    let size_scale = (parent_radius_px / base_reference_radius_px).clamp(0.6, 1.8);

    // Foreshorten Y first (matches the shader's R(theta) * S convention).
    // Jupiter has its own hardcoded 3° axial tilt; Saturn picks up the live
    // ring tilt so its moon sweeps in the same plane as the rings.
    let vertical_foreshorten = if matches!(parent, PlanetIdentity::Jupiter) {
        3.0_f64.to_radians().sin()
    } else {
        ring_tilt_deg.to_radians().sin()
    };

    let theta = rotation_deg.to_radians();
    let cos_theta = theta.cos();
    let sin_theta = theta.sin();
    let (cx, cy) = parent_center_px;

    for moon in defs {
        let angle = (2.0 * std::f64::consts::PI * days_since_epoch / moon.period_days)
            + moon.initial_phase_rad;
        let x = moon.semi_major_axis_planet_radii * angle.cos();
        let y = moon.semi_major_axis_planet_radii * angle.sin();

        let yp = y * vertical_foreshorten;
        let xr = x * cos_theta - yp * sin_theta;
        let yr = x * sin_theta + yp * cos_theta;

        let screen_x = cx + xr * parent_radius_px;
        let screen_y = cy + yr * parent_radius_px;

        // Z-cull: positive y in the unrotated frame == "behind" the planet
        // from the viewer's perspective. Hide if also inside the screen disc.
        let dist = (screen_x - cx).hypot(screen_y - cy);
        if y > 0.0 && dist < parent_radius_px {
            continue;
        }

        let size_px = (moon.base_size_px * moon_scale * size_scale).clamp(1.0, 3.0) as f32;
        push(MoonSpriteState {
            name: moon.name,
            center_px: (screen_x, screen_y),
            size_px,
            color: moon.color,
            alpha: 0.78,
        });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn time_at_unix(secs: f64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs_f64(secs)
    }

    #[test]
    fn julian_day_at_unix_epoch_is_2440587_5() {
        let jd = julian_day(UNIX_EPOCH);
        assert!(
            (jd - UNIX_EPOCH_AS_JD).abs() < 1e-9,
            "expected {}, got {jd}",
            UNIX_EPOCH_AS_JD
        );
    }

    #[test]
    fn normalise_wraps_at_360_and_handles_negatives() {
        assert!((normalise(0.0)).abs() < 1e-9);
        assert!((normalise(360.0)).abs() < 1e-9);
        assert!((normalise(720.5) - 0.5).abs() < 1e-9);
        assert!((normalise(-1.0) - 359.0).abs() < 1e-9);
        assert!((normalise(-720.0)).abs() < 1e-9);
    }

    #[test]
    fn orbital_elements_distinct_per_planet() {
        let mut seen = std::collections::HashSet::new();
        for id in PlanetIdentity::ALL {
            let e = orbital_elements(id);
            // (L0, a, e0) fingerprint distinguishes every planet.
            let key = (e.l0.to_bits(), e.a.to_bits(), e.e0.to_bits());
            assert!(
                seen.insert(key),
                "duplicate elements for {id:?} — table likely has a copy-paste bug"
            );
        }
    }

    #[test]
    fn phase_fraction_in_unit_range_for_each_planet_at_j2000() {
        // J2000.0 = 2000-01-01 12:00 TT ≈ unix 946_728_000.
        let t = time_at_unix(946_728_000.0);
        for id in PlanetIdentity::ALL {
            let (frac, sign) = phase_state(id, t);
            assert!(
                (0.0..=1.0).contains(&frac),
                "{id:?} phase fraction out of [0,1]: {frac}"
            );
            assert!(
                sign == 1.0 || sign == -1.0,
                "{id:?} waxing sign must be ±1.0, got {sign}"
            );
        }
    }

    #[test]
    fn frame_state_hide_mode_invariants() {
        // For every planet at a representative time:
        //   above_horizon == true  → brightness 1.0
        //   above_horizon == false → brightness 0.0 AND off-screen (negative coords)
        let t = time_at_unix(1_704_067_200.0); // 2024-01-01 UTC
        let mut saw_above = false;
        let mut saw_below = false;
        for id in PlanetIdentity::ALL {
            let p = Planet::new(id, 1280, 800, 200, 10, BelowHorizonBehavior::Hide, 0);
            let s = p.frame_state(t);
            if s.above_horizon {
                saw_above = true;
                assert_eq!(s.brightness, 1.0, "{id:?} above-horizon brightness");
            } else {
                saw_below = true;
                assert_eq!(s.brightness, 0.0, "{id:?} below-horizon brightness");
                assert!(
                    s.center_px.0 < 0.0 && s.center_px.1 < 0.0,
                    "{id:?} below-horizon centre should be off-screen, got {:?}",
                    s.center_px
                );
            }
        }
        // 8 planets at a fixed time will almost certainly hit both branches.
        // The assertion below catches a misconfigured observer or broken
        // ephemeris that pegs everything above or below the horizon.
        assert!(
            saw_above || saw_below,
            "no planet was above OR below horizon — ephemeris is broken"
        );
    }

    #[test]
    fn frame_state_random_mode_is_deterministic_per_day_and_responds_to_nonce() {
        let t = time_at_unix(1_704_067_200.0);
        let p_a1 = Planet::new(
            PlanetIdentity::Jupiter,
            1280,
            800,
            200,
            16,
            BelowHorizonBehavior::Random,
            42,
        );
        let p_a2 = Planet::new(
            PlanetIdentity::Jupiter,
            1280,
            800,
            200,
            16,
            BelowHorizonBehavior::Random,
            42,
        );
        let p_b = Planet::new(
            PlanetIdentity::Jupiter,
            1280,
            800,
            200,
            16,
            BelowHorizonBehavior::Random,
            99,
        );
        let s_a1 = p_a1.frame_state(t);
        let s_a2 = p_a2.frame_state(t);
        let s_b = p_b.frame_state(t);

        // Same nonce, same day, same planet → same position.
        assert_eq!(s_a1.center_px, s_a2.center_px, "deterministic per day");
        // Random mode reports below_horizon regardless of actual orbital position.
        assert!(
            !s_a1.above_horizon,
            "random mode should report below horizon"
        );
        assert_eq!(
            s_a1.brightness, 1.0,
            "random mode renders at full brightness"
        );
        // Different nonce → different position (overwhelmingly likely).
        assert_ne!(
            s_a1.center_px, s_b.center_px,
            "nonce should shuffle position"
        );
    }

    #[test]
    fn saturn_ring_state_within_physical_bounds_and_only_saturn() {
        // Sample a year's worth of dates roughly every 30 days. Tilt B must
        // physically stay within ±28.06° (Saturn's axial tilt); position
        // angle wraps to (-180, 180]. These are the only invariants we can
        // assert without an external ephemeris source.
        let start_unix: f64 = 1_704_067_200.0; // 2024-01-01 UTC
        for step in 0..13 {
            let t = time_at_unix(start_unix + (step as f64) * 30.0 * 86_400.0);
            let (tilt, pa) = saturn_ring_state(t);
            assert!(
                tilt.abs() <= 28.06,
                "saturn ring tilt out of physical bounds: {tilt}° at step {step}"
            );
            assert!(
                (-180.0..=180.0).contains(&pa),
                "saturn ring position angle out of normalised range: {pa}° at step {step}"
            );
        }

        // Non-Saturn planets must always report (0.0, 0.0) for ring fields
        // — the Saturn-specific path is gated by identity.
        let t = time_at_unix(1_704_067_200.0);
        for id in PlanetIdentity::ALL {
            if id == PlanetIdentity::Saturn {
                continue;
            }
            let p = Planet::new(id, 1280, 800, 200, 16, BelowHorizonBehavior::Hide, 42);
            let s = p.frame_state(t);
            assert_eq!(
                (s.ring_tilt_deg, s.ring_rotation_deg),
                (0.0, 0.0),
                "{id:?} must have zero ring fields"
            );
        }
    }

    #[test]
    fn normalise_signed_wraps_to_minus180_to_180() {
        assert!((normalise_signed(0.0)).abs() < 1e-9);
        assert!((normalise_signed(180.0) - (-180.0)).abs() < 1e-9);
        assert!((normalise_signed(-180.0) - (-180.0)).abs() < 1e-9);
        assert!((normalise_signed(190.0) - (-170.0)).abs() < 1e-9);
        assert!((normalise_signed(-190.0) - 170.0).abs() < 1e-9);
        assert!((normalise_signed(540.0) - (-180.0)).abs() < 1e-9);
    }

    #[test]
    fn moon_sprite_states_zero_radius_returns_empty() {
        let now = time_at_unix(1_704_067_200.0);
        for parent in PlanetIdentity::ALL {
            let mut states = Vec::new();
            moon_sprite_states(parent, now, (640.0, 400.0), 0.0, 0.0, 0.0, 1.0, |s| {
                states.push(s)
            });
            assert!(
                states.is_empty(),
                "{parent:?} with parent_radius_px=0 must return empty, got {} moons",
                states.len()
            );
        }
    }

    #[test]
    fn moon_sprite_states_only_jupiter_and_saturn_have_moons() {
        let now = time_at_unix(1_704_067_200.0);
        for parent in PlanetIdentity::ALL {
            let mut states = Vec::new();
            moon_sprite_states(parent, now, (640.0, 400.0), 30.0, 5.0, 12.0, 1.0, |s| {
                states.push(s)
            });
            match parent {
                PlanetIdentity::Jupiter => assert!(
                    states.len() <= 4,
                    "Jupiter has at most 4 Galilean moons, got {}",
                    states.len()
                ),
                PlanetIdentity::Saturn => assert!(
                    states.len() <= 1,
                    "Saturn has at most 1 (Titan), got {}",
                    states.len()
                ),
                _ => assert!(
                    states.is_empty(),
                    "{parent:?} should have no moons in our model, got {}",
                    states.len()
                ),
            }
        }
    }

    #[test]
    fn moon_sprite_states_jupiter_names_alpha_and_size_within_bounds() {
        let now = time_at_unix(1_704_067_200.0);
        let mut states = Vec::new();
        moon_sprite_states(
            PlanetIdentity::Jupiter,
            now,
            (640.0, 400.0),
            30.0,
            5.0,
            12.0,
            1.0,
            |s| states.push(s),
        );
        let known = ["io", "europa", "ganymede", "callisto"];
        let mut seen = std::collections::HashSet::new();
        for s in &states {
            assert!(
                known.contains(&s.name),
                "unexpected moon name {:?} for Jupiter",
                s.name
            );
            assert!(
                seen.insert(s.name),
                "duplicate moon name {:?} in same call",
                s.name
            );
            assert_eq!(s.alpha, 0.78, "alpha must be exactly 0.78");
            assert!(
                (1.0..=3.0).contains(&s.size_px),
                "size_px {} not in [1, 3]",
                s.size_px
            );
        }
    }

    #[test]
    fn moon_sprite_states_saturn_only_emits_titan() {
        let now = time_at_unix(1_704_067_200.0);
        let mut states = Vec::new();
        moon_sprite_states(
            PlanetIdentity::Saturn,
            now,
            (640.0, 400.0),
            30.0,
            15.0,
            45.0,
            1.0,
            |s| states.push(s),
        );
        for s in &states {
            assert_eq!(s.name, "titan", "Saturn only emits Titan");
            assert_eq!(s.alpha, 0.78);
            assert!((1.0..=3.0).contains(&s.size_px));
        }
    }

    #[test]
    fn moon_sprite_states_scale_multiplier_drives_size_to_clamp_bounds() {
        // scale=4.0 with parent_radius_px=30 (size_scale=1.25) drives every
        // moon size to >=10 px, so all visible ones saturate at the upper
        // clamp 3.0. scale=0.5 with parent_radius_px=1.0 (size_scale clamped
        // to 0.6) drives every moon to <=0.75 px, saturating at the lower
        // clamp 1.0. Callisto is structurally never z-culled (a > 1) so the
        // result vec is guaranteed non-empty in both cases.
        let now = time_at_unix(1_704_067_200.0);
        let mut big = Vec::new();
        moon_sprite_states(
            PlanetIdentity::Jupiter,
            now,
            (640.0, 400.0),
            30.0,
            0.0,
            0.0,
            4.0,
            |s| big.push(s),
        );
        assert!(!big.is_empty(), "scale=4 should produce visible moons");
        for s in &big {
            assert_eq!(
                s.size_px, 3.0,
                "scale=4.0 should saturate at clamp upper bound, got {}",
                s.size_px
            );
        }
        let mut tiny = Vec::new();
        moon_sprite_states(
            PlanetIdentity::Jupiter,
            now,
            (640.0, 400.0),
            1.0,
            0.0,
            0.0,
            0.5,
            |s| tiny.push(s),
        );
        assert!(!tiny.is_empty(), "scale=0.5 should produce visible moons");
        for s in &tiny {
            assert_eq!(
                s.size_px, 1.0,
                "scale=0.5 should saturate at clamp lower bound, got {}",
                s.size_px
            );
        }
    }
}
