//! Moon simulation: position (left→right arched traversal), phase
//! (illuminated fraction + waxing/waning flag), and the per-frame
//! `MoonParams` packet handed to `moon_renderer::MoonRenderer`.
//!
//! Rust port of `Moon.swift`. Keeps the Swift behaviour pixel-for-pixel:
//!
//! - Position is wall-clock-modulo driven (`progress = (unix_secs %
//!   traversal_seconds) / traversal_seconds`), so any two `Moon` instances
//!   started at different times stay synchronised. The horizontal sweep is
//!   linear; the vertical motion is a half-sine arch with `verticalBaseY`
//!   and `verticalArchHeight` randomized once at construction.
//! - Phase is derived from the real-world synodic month against a hard-coded
//!   reference new-moon epoch (2000-01-06 18:14 UTC). When
//!   `phase_override_enabled` is true the slider value drives a triangular
//!   wave instead (`p ≤ 0.5` waxing up, `p > 0.5` waning down).
//!
//! Texture generation lives in `moon_texture.rs`; GPU resources live in
//! `moon_renderer.rs`. This module is pure simulation data — no wgpu.
//!
//! `MoonParams` is colocated here (rather than in `types.rs`) to match the
//! existing convention from `sprite.rs::SpriteInstance`: the data type a
//! layer's engine code emits each frame lives next to that layer's
//! simulation code, not in the shared types module.

use std::f64::consts::PI;
use std::time::{SystemTime, UNIX_EPOCH};

use rand::Rng;

/// Real-world synodic month (days). Used by the live-phase calculation.
pub const SYNODIC_MONTH_DAYS: f64 = 29.530588853;

/// Reference new moon epoch as Unix time (seconds). Equivalent to
/// `2000-01-06 18:14:00 UTC`. Hard-coded literal so we don't need a date
/// library just to bootstrap one constant. Verify by:
///
/// ```text
/// $ date -u -j -f "%Y-%m-%d %H:%M:%S" "2000-01-06 18:14:00" "+%s"
/// 947182440
/// ```
pub const NEW_MOON_EPOCH_UNIX_SECS: f64 = 947_182_440.0;

/// Default traversal duration (seconds) — 1 hour, matches Swift's
/// `traversalSeconds` parameter default.
pub const DEFAULT_TRAVERSAL_SECONDS: f64 = 3600.0;

/// Derive moon radius in pixels from a viewport width and a diameter
/// percentage (`Config::moon_diameter_percent`). Used by both the
/// `Engine` (to size the `Moon`) and the renderer (to size its albedo
/// texture). Floored at 1px so a degenerate (very small or zero) percent
/// still produces a drawable disc.
///
/// Formula: `radius = (percent * width) / 2`. Matches Swift's
/// `MoonConfig.radius` derivation.
pub fn radius_from_percent(screen_width: i32, diameter_percent: f64) -> i32 {
    let diameter = diameter_percent * screen_width as f64;
    let radius = (diameter / 2.0).max(1.0);
    radius as i32
}

/// Convert a `SystemTime` to its Julian Day number.
///
/// Mirrors `Moon.julianDay(from:)` in the Swift source:
/// `JD = 2440587.5 + unix_seconds / 86400`. `SystemTime` before the Unix
/// epoch is unrepresentable in practice for our use case, so we collapse
/// it to `JD(epoch) = 2440587.5`.
pub fn julian_day(now: SystemTime) -> f64 {
    let secs = now
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    2_440_587.5 + secs / 86_400.0
}

/// Compute live moon phase at the given instant.
///
/// Returns `(illuminated_fraction, waxing)`:
/// - `illuminated_fraction` ∈ `[0, 1]` (0 = new, 1 = full)
/// - `waxing` is `true` for the growing half of the cycle, `false` for the
///   waning half.
///
/// Direct port of `Moon.computePhase(on:)`.
pub fn compute_phase(now: SystemTime) -> (f64, bool) {
    let jd = julian_day(now);
    let epoch_jd = 2_440_587.5 + NEW_MOON_EPOCH_UNIX_SECS / 86_400.0;
    let days = jd - epoch_jd;
    let age_raw = days.rem_euclid(SYNODIC_MONTH_DAYS);
    // rem_euclid already returns [0, SYNODIC_MONTH_DAYS); no manual wrap needed.
    let cycle_portion = age_raw / SYNODIC_MONTH_DAYS;
    let phase_angle = 2.0 * PI * cycle_portion;
    let fraction = 0.5 * (1.0 - phase_angle.cos());
    let waxing = age_raw < (SYNODIC_MONTH_DAYS / 2.0);
    (fraction.clamp(0.0, 1.0), waxing)
}

/// Per-frame snapshot returned by [`Moon::frame_state`]. Bundled so the
/// engine hot path avoids redundant `SystemTime` arithmetic and redundant
/// phase calculations.
#[derive(Copy, Clone, Debug)]
pub struct MoonFrameState {
    /// Moon centre in pixel coordinates (bottom-left origin, Y-up —
    /// matches the existing sprite/skyline shader convention; see
    /// `shader.wgsl` line 29).
    pub center: (f32, f32),
    /// Illuminated fraction `[0, 1]`.
    pub illuminated_fraction: f64,
    /// `true` if the moon is currently in the waxing half of its cycle.
    pub waxing: bool,
}

/// The moon simulation: static geometry (radius, randomized arch
/// parameters) plus dynamic position/phase queries against a caller-
/// supplied `SystemTime`. No interior mutability, no clock ownership — the
/// engine owns the clock and threads `now` through every call.
pub struct Moon {
    /// Moon radius in pixels (≥ 1).
    pub radius: i32,
    /// Screen width in pixels at construction time.
    pub screen_width: i32,
    /// Screen height in pixels at construction time.
    pub screen_height: i32,
    /// Full left→right traversal duration in seconds.
    pub traversal_seconds: f64,

    // Randomized-once arch parameters. Private so callers can't mutate the
    // baseline mid-flight — they're sampled in `new()` against the
    // building skyline.
    vertical_base_y: f64,
    vertical_arch_height: f64,

    // Phase override. Triangular wave when enabled.
    phase_override_enabled: bool,
    phase_override_value_clamped: f64,
}

impl Moon {
    /// Construct a new `Moon`.
    ///
    /// - `building_max_height`: the tallest building's top (in pixels from
    ///   the top of the screen). Used to clamp the arch baseline so the
    ///   moon never clips into the skyline.
    /// - `radius`: moon radius in pixels (clamped to ≥ 1).
    /// - `traversal_seconds`: full left→right cycle duration. Values ≤ 1.0
    ///   are coerced to [`DEFAULT_TRAVERSAL_SECONDS`] to avoid div-by-zero
    ///   and visually-jarring near-instant traversals.
    /// - `phase_override_enabled` / `phase_override_value`: when enabled,
    ///   the triangular slider value (clamped to `[0, 1]`) overrides the
    ///   live phase calculation.
    /// - `rng`: source of randomness for the arch baseline/peak. Taking
    ///   `&mut impl Rng` lets the engine pass through its seeded
    ///   `StdRng` for deterministic playback.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        screen_width: i32,
        screen_height: i32,
        building_max_height: i32,
        radius: i32,
        traversal_seconds: f64,
        phase_override_enabled: bool,
        phase_override_value: f64,
        rng: &mut impl Rng,
    ) -> Self {
        let radius = radius.max(1);
        let traversal_seconds = if traversal_seconds > 1.0 {
            traversal_seconds
        } else {
            DEFAULT_TRAVERSAL_SECONDS
        };

        // --- Vertical arch randomization (matches Swift). ---
        //
        // baseline band:
        //   min = max(building_max_height + radius + 10, radius + 10)
        //   max = min(min_base + 10% of screen height, screen_height - radius - 10)
        // If the band collapses (e.g. very short screen) we fall back to min.
        let min_base_unclamped = building_max_height + radius + 10;
        let min_base = min_base_unclamped.max(radius + 10);
        let base_upper_candidate = min_base + ((0.10_f64) * screen_height as f64) as i32;
        let max_base_allowed = screen_height - radius - 10;
        let base_upper = base_upper_candidate.min(max_base_allowed);
        let chosen_base = if base_upper >= min_base {
            rng.gen_range(min_base..=base_upper)
        } else {
            min_base
        };
        let vertical_base_y = chosen_base as f64;

        // Arch peak: at least 20px, target 15% of screen height, never
        // exceeding the headroom between baseline and the top margin.
        let vertical_headroom = (screen_height - radius) as f64 - vertical_base_y - 10.0;
        let suggested = 0.15 * screen_height as f64;
        let min_arch = 20.0;
        let vertical_arch_height = suggested.max(min_arch).min(vertical_headroom.max(0.0));

        let phase_override_value_clamped = phase_override_value.clamp(0.0, 1.0);

        Self {
            radius,
            screen_width,
            screen_height,
            traversal_seconds,
            vertical_base_y,
            vertical_arch_height,
            phase_override_enabled,
            phase_override_value_clamped,
        }
    }

    /// Compute the moon's centre at `now`.
    ///
    /// Returns pixel coordinates `(x, y)` with the same orientation as the
    /// existing skyline/satellite/shooting-star renderers (origin
    /// bottom-left, Y-up — see `shader.wgsl` line 29). Direct port of
    /// `Moon.currentCenter(now:)`.
    pub fn current_center(&self, now: SystemTime) -> (f32, f32) {
        let cycle = if self.traversal_seconds > 0.0 {
            self.traversal_seconds
        } else {
            DEFAULT_TRAVERSAL_SECONDS
        };
        let t = now
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        let cycle_elapsed = t.rem_euclid(cycle);
        let progress = cycle_elapsed / cycle;

        let usable_width = (self.screen_width - 2 * self.radius) as f64;
        let left_x = self.radius as f64;
        // Always moving left→right (the Swift `movingLeftToRight` field is
        // hardcoded `true`; we just dropped it).
        let x = progress * usable_width + left_x;
        let y = self.vertical_base_y + self.vertical_arch_height * (PI * progress).sin();

        (x as f32, y as f32)
    }

    /// Compute illuminated fraction and waxing state at `now`. Honours
    /// the phase override.
    pub fn current_illumination(&self, now: SystemTime) -> (f64, bool) {
        if self.phase_override_enabled {
            let p = self.phase_override_value_clamped;
            if p <= 0.5 {
                (2.0 * p, true)
            } else {
                (2.0 - 2.0 * p, false)
            }
        } else {
            compute_phase(now)
        }
    }

    /// Hot-path convenience: position + phase in one call, computing each
    /// derived value exactly once.
    pub fn frame_state(&self, now: SystemTime) -> MoonFrameState {
        let center = self.current_center(now);
        let (illuminated_fraction, waxing) = self.current_illumination(now);
        MoonFrameState {
            center,
            illuminated_fraction,
            waxing,
        }
    }

    pub fn radius(&self) -> i32 {
        self.radius
    }
}

/// Per-frame moon parameters emitted by the engine and consumed by
/// `moon_renderer::MoonRenderer` (Step 5).
///
/// This is the simulation→renderer interface; the renderer packs it into
/// the GPU UBO layout (mirrors Metal's `MoonUniforms` 3-`vec4` packing)
/// at draw time.
#[derive(Copy, Clone, Debug)]
pub struct MoonParams {
    /// Pixel centre of the moon (bottom-left origin, Y-up — matches the
    /// skyline/sprite shader convention).
    pub center_px: [f32; 2],
    /// Moon radius in pixels.
    pub radius_px: f32,
    /// Illuminated fraction `[0, 1]` (0 = new, 1 = full).
    pub phase_fraction: f32,
    /// Multiplier for the lit hemisphere (default 1.0; configurable).
    pub bright_brightness: f32,
    /// Multiplier for the unlit hemisphere (default 0.15; configurable).
    pub dark_brightness: f32,
    /// `+1.0` waxing, `-1.0` waning — drives terminator orientation.
    pub waxing_sign: f32,
    /// `0` = hard step, `1` = smooth, `2` = banded.
    pub terminator_mode: u32,
    /// Half-width of the smooth transition (modes 1 + 2).
    pub terminator_width: f32,
    /// Number of discrete brightness bands (mode 2 only).
    pub terminator_bands: u32,
    /// When `true`, the fragment shader renders the texture albedo only
    /// (no lighting) — useful for visually debugging the procedural
    /// crater map. Wired to the `--debug-moon-colors` CLI flag.
    pub debug_show_mask: bool,
}

impl MoonParams {
    /// Construct from a [`MoonFrameState`] + the configuration knobs the
    /// engine carries (brightnesses + terminator settings). Keeps the
    /// engine code free of waxing→sign conversion boilerplate.
    #[allow(clippy::too_many_arguments)]
    pub fn from_frame_state(
        state: MoonFrameState,
        radius_px: f32,
        bright_brightness: f32,
        dark_brightness: f32,
        terminator_mode: u32,
        terminator_width: f32,
        terminator_bands: u32,
        debug_show_mask: bool,
    ) -> Self {
        Self {
            center_px: [state.center.0, state.center.1],
            radius_px,
            phase_fraction: state.illuminated_fraction as f32,
            bright_brightness,
            dark_brightness,
            waxing_sign: if state.waxing { 1.0 } else { -1.0 },
            terminator_mode,
            terminator_width,
            terminator_bands,
            debug_show_mask,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// At the reference new-moon epoch we expect illuminated fraction ≈ 0
    /// and the cycle ticking into the waxing half.
    #[test]
    fn phase_at_epoch_is_new_and_waxing() {
        let epoch = UNIX_EPOCH + Duration::from_secs_f64(NEW_MOON_EPOCH_UNIX_SECS);
        let (frac, waxing) = compute_phase(epoch);
        assert!(
            frac < 1e-9,
            "expected ~0 illumination at new moon, got {frac}"
        );
        assert!(waxing, "expected waxing immediately after new moon");
    }

    /// Half a synodic month after the epoch we expect a full moon: ~1.0
    /// illumination. Waxing flag is `age < synodic/2`, so at exactly
    /// `synodic/2` it tips to `false` (waning) — that's the documented
    /// Swift behaviour, so we match it.
    #[test]
    fn phase_at_full_moon_is_one_and_tips_to_waning() {
        let half_synodic_secs = SYNODIC_MONTH_DAYS * 86_400.0 / 2.0;
        let full =
            UNIX_EPOCH + Duration::from_secs_f64(NEW_MOON_EPOCH_UNIX_SECS + half_synodic_secs);
        let (frac, waxing) = compute_phase(full);
        assert!(
            (frac - 1.0).abs() < 1e-9,
            "expected full illumination at half-synodic, got {frac}"
        );
        assert!(
            !waxing,
            "waxing flag should tip to false at exactly synodic/2"
        );
    }

    /// Override `p = 0.25` should give illuminated fraction `0.5`, waxing.
    #[test]
    fn override_waxing_half() {
        // RNG only matters for arch randomization, not for the override path.
        let mut rng = rand::rngs::StdRng::seed_from_u64(0);
        use rand::SeedableRng;
        let moon = Moon::new(1280, 800, 100, 60, 3600.0, true, 0.25, &mut rng);
        let (frac, waxing) = moon.current_illumination(UNIX_EPOCH);
        assert!((frac - 0.5).abs() < 1e-12);
        assert!(waxing);
    }

    /// Override `p = 0.75` should give illuminated fraction `0.5`, waning.
    #[test]
    fn override_waning_half() {
        use rand::SeedableRng;
        let mut rng = rand::rngs::StdRng::seed_from_u64(0);
        let moon = Moon::new(1280, 800, 100, 60, 3600.0, true, 0.75, &mut rng);
        let (frac, waxing) = moon.current_illumination(UNIX_EPOCH);
        assert!((frac - 0.5).abs() < 1e-12);
        assert!(!waxing);
    }

    /// Position at `t=0` (Unix epoch) with `traversal=3600` puts us at
    /// `progress=0` → `x = radius` (left edge of usable band), `y =
    /// vertical_base_y`. Sanity-check x; y is randomized so we only check
    /// it equals the structurally-known baseline.
    #[test]
    fn position_at_progress_zero_is_left_edge_on_baseline() {
        use rand::SeedableRng;
        let mut rng = rand::rngs::StdRng::seed_from_u64(42);
        let moon = Moon::new(1280, 800, 100, 60, 3600.0, false, 0.0, &mut rng);
        let (x, y) = moon.current_center(UNIX_EPOCH);
        assert!((x - moon.radius as f32).abs() < 1e-3);
        assert!((y as f64 - moon.vertical_base_y).abs() < 1e-3);
    }
}
