//! Satellites layer: spawns small bright points that traverse the sky
//! horizontally at a fixed speed. Each active satellite emits ONE head
//! sprite per frame — the satellite "trail" effect is produced entirely
//! by the layer's GPU decay pass smearing prior frames' heads. This is
//! intentionally different from the shooting-stars layer, which emits a
//! tapered 18-segment trail per star per frame.
//!
//! Rust port of [`SatellitesLayerRenderer.swift`](../../StarryExcuseForAMacScreensaver/SatellitesLayerRenderer.swift).
//! Three deliberate departures from the Swift original:
//!
//! 1. **Determinism.** Uses the engine-seeded `StdRng` (threaded as
//!    `&mut R: Rng`) instead of Swift's `SystemRandomNumberGenerator`.
//! 2. **Y-coord interpretation is direct.** The Swift implementation
//!    talks about a top-origin "raw" coord that gets flipped by an
//!    external transform; our renderer is bottom-origin throughout, so
//!    we apply the flasher constraint directly without the flip
//!    indirection. The flasher constraint still means "satellites spawn
//!    visually above the flasher" — same end result.
//! 3. **No runtime mutation / debug overlay.** `setEnabled`,
//!    `updateParameters`, `setDebugOverlayEnabled`, debug spawn-bounds
//!    visualization — all skipped here. They land in a later phase
//!    alongside the broader debug-overlay surface.

use rand::Rng;

use crate::sprite::SpriteInstance;

/// Extra gap (pixels) between flasher and the minimum satellite center —
/// keeps a small visual breathing zone above the flasher. Matches Swift's
/// `flasherVerticalGap` (line 67).
const FLASHER_VERTICAL_GAP: f32 = 4.0;

/// Default vertical band when no flasher is present: 5% from top/bottom.
/// Matches Swift's legacy band (line 271).
const DEFAULT_BAND_TOP_FRAC: f32 = 0.05;
const DEFAULT_BAND_BOTTOM_FRAC: f32 = 0.95;

/// One in-flight satellite. Pure simulation state — sprite emission
/// happens once per frame in `frame()`, never cached on the satellite.
#[derive(Copy, Clone, Debug)]
struct Satellite {
    x: f32,
    y: f32,
    vx: f32, // signed (positive = left→right, negative = right→left)
    size: f32,
    brightness: f32,
}

/// Per-frame output. Sprites borrow into an internal buffer reused
/// across calls; `keep_factor` feeds the layer's decay pass this frame
/// (`new = old * keep_factor`, see `decay.rs`). When `trailing` is
/// disabled, `keep_factor` is always 0.0 — the decay pass wipes the
/// layer to transparent every frame and no trail is visible.
pub struct SatellitesFrame<'a> {
    pub sprites: &'a [SpriteInstance],
    pub keep_factor: f32,
}

/// Per-frame satellite simulator + sprite emitter. Owns the live list
/// of in-flight satellites; advances them, prunes off-screen ones,
/// rolls the exponential spawn schedule, and emits one head sprite per
/// survivor.
pub struct SatellitesRenderer {
    width: i32,
    height: i32,

    avg_spawn_seconds: f64,
    speed: f32,
    size_px: f32,
    brightness: f32,
    trailing: bool,
    trail_half_life_s: f32,

    flasher_center_y: Option<f32>,
    flasher_radius: Option<f32>,

    satellites: Vec<Satellite>,
    sprites: Vec<SpriteInstance>,
    time_until_next_spawn: f64,
}

impl SatellitesRenderer {
    /// `flasher_center_y` and `flasher_radius` should both be `Some(_)` if
    /// the skyline has a flasher (read from `skyline.flasher_pos.y` and
    /// `skyline.flasher_radius`), or both `None` to use the default
    /// full-canvas spawn band. Coord convention is **bottom-origin**:
    /// `flasher_center_y` is the flasher's center pixel from the bottom
    /// edge, matching `Skyline::flasher_pos`.
    ///
    /// Numeric clamping mirrors Swift line 106-114: `avg_spawn_seconds`
    /// floored at 0.05s, `size` at 1.0px, `brightness` to [0,1]. The
    /// `trail_half_life_s` parameter is floored at 0 — a value of 0 (or
    /// `trailing: false`) wipes the layer to transparent every frame.
    /// `time_until_next_spawn` is sampled during construction so the
    /// first spawn happens at a realistic interval from t=0 rather than
    /// instantly.
    #[allow(clippy::too_many_arguments)]
    pub fn new<R: Rng + ?Sized>(
        width: i32,
        height: i32,
        avg_spawn_seconds: f64,
        speed: f32,
        size: f32,
        brightness: f32,
        trailing: bool,
        trail_half_life_s: f32,
        flasher_center_y: Option<f32>,
        flasher_radius: Option<f32>,
        rng: &mut R,
    ) -> Self {
        let avg = avg_spawn_seconds.max(0.05);
        let mut s = Self {
            width,
            height,
            avg_spawn_seconds: avg,
            speed,
            size_px: size.max(1.0),
            brightness: brightness.clamp(0.0, 1.0),
            trailing,
            trail_half_life_s: trail_half_life_s.max(0.0),
            flasher_center_y,
            flasher_radius: flasher_radius.map(|r| r.max(0.0)),
            satellites: Vec::new(),
            sprites: Vec::with_capacity(32),
            time_until_next_spawn: 0.0,
        };
        s.schedule_next_spawn(rng);
        s
    }

    /// Advance every active satellite by `dt`, prune any that have fully
    /// exited the canvas, roll the exponential spawn timer (at most one
    /// new spawn per frame — see in-line note), emit one head sprite per
    /// survivor, and return `(sprites, keep_factor)`. Borrows into an
    /// internal buffer — caller must drain before next call.
    pub fn frame<R: Rng + ?Sized>(&mut self, dt: f64, rng: &mut R) -> SatellitesFrame<'_> {
        let dtf = dt as f32;
        for sat in self.satellites.iter_mut() {
            sat.x += sat.vx * dtf;
        }
        // Cull off-screen — fully exited on the side they're moving toward.
        // Swift uses `x - size > width` / `x + size < 0` (line 386-388).
        self.satellites.retain(|s| {
            !((s.vx > 0.0 && s.x - s.size > self.width as f32)
                || (s.vx < 0.0 && s.x + s.size < 0.0))
        });

        self.time_until_next_spawn -= dt;
        // Single-spawn-per-frame even if multiple intervals elapsed in a
        // long dt. Swift uses `while + break` (line 393-397) — identical
        // semantics, expressed more honestly here. If the timer is still
        // negative after this, the next frame catches up — fine for our
        // soft "average rate" guarantee.
        if self.time_until_next_spawn <= 0.0 {
            self.spawn(rng);
            self.schedule_next_spawn(rng);
        }

        self.sprites.clear();
        for sat in &self.satellites {
            // Color = (b, b, b, 1.0). Pre-multiplied with alpha=1 the
            // numbers don't change, but emitting through the same blend
            // pipeline as the rest of the additive layers keeps the
            // composite math uniform.
            let color = [sat.brightness, sat.brightness, sat.brightness, 1.0];
            self.sprites
                .push(SpriteInstance::new([sat.x, sat.y], sat.size, color));
        }

        // keep_factor = 0.5^(dt/halfLife), clamped to [0, 1]. Direct
        // half-life formulation (see `shooting_stars.rs::frame` for the
        // full rationale on departing from Swift's two-step decay).
        // `trailing: false` or `half_life <= 0` collapses to 0 so the
        // decay pass wipes the layer to transparent every frame.
        let keep_factor = if !self.trailing || self.trail_half_life_s <= 0.0 {
            0.0
        } else {
            (0.5_f64.powf(dt / self.trail_half_life_s as f64) as f32).clamp(0.0, 1.0)
        };

        SatellitesFrame {
            sprites: &self.sprites,
            keep_factor,
        }
    }

    /// Exponential next-spawn interval: `-ln(1-u) * mean`. `u` is
    /// clamped away from {0, 1} to avoid `ln(0)` infinities — matches
    /// Swift line 246 (`0.00001 ... 0.99999`).
    fn schedule_next_spawn<R: Rng + ?Sized>(&mut self, rng: &mut R) {
        let u: f64 = rng.gen_range(0.00001..=0.99999);
        self.time_until_next_spawn = -(1.0 - u).ln() * self.avg_spawn_seconds;
    }

    fn spawn<R: Rng + ?Sized>(&mut self, rng: &mut R) {
        let Some((band_min, band_max)) = self.current_spawn_band() else {
            // Flasher leaves no vertical room — drop this spawn attempt.
            // The next schedule_next_spawn will pick a fresh interval.
            return;
        };

        let from_left: bool = rng.gen_bool(0.5);
        let y = if band_max > band_min {
            rng.gen_range(band_min..=band_max)
        } else {
            band_min
        };
        // Start fully off-screen on the entering side so the satellite
        // visibly "flies in" rather than popping into existence at the
        // edge. Direction determines both start x and velocity sign.
        let x = if from_left {
            -self.size_px
        } else {
            self.width as f32 + self.size_px
        };
        let vx = if from_left { self.speed } else { -self.speed };
        // Per-satellite brightness jitter (0.8x .. 1.05x) so a parade of
        // satellites doesn't look mechanically identical. Swift line 336.
        let brightness = self.brightness * rng.gen_range(0.8_f32..=1.05);

        self.satellites.push(Satellite {
            x,
            y,
            vx,
            size: self.size_px,
            brightness,
        });
    }

    /// Compute the valid vertical band for new satellite centers.
    /// Returns `None` when the flasher fills all available vertical
    /// space and no spawn is possible. The y-axis interpretation:
    /// **bottom-origin** (y=0 at horizon, increases upward), matching
    /// the rest of the Rust port. The flasher constraint
    /// `sat_center_y - D/2 >= flasher_top + gap` enforces "satellites
    /// strictly above the flasher's upper edge plus gap".
    fn current_spawn_band(&self) -> Option<(f32, f32)> {
        let h = self.height as f32;
        let mut y_min = h * DEFAULT_BAND_TOP_FRAC;
        let mut y_max = h * DEFAULT_BAND_BOTTOM_FRAC;

        if let (Some(cy), Some(r)) = (self.flasher_center_y, self.flasher_radius) {
            // Bottom-origin: "top of flasher" = center + radius.
            let flasher_top = cy + r;
            let limit_min_center = flasher_top + FLASHER_VERTICAL_GAP + self.size_px * 0.5;
            if limit_min_center > h {
                return None;
            }
            y_min = y_min.max(limit_min_center);
            if y_min > y_max {
                return None;
            }
        }

        // Defensive clamp to [0, h] in case constants ever change.
        y_min = y_min.clamp(0.0, h);
        y_max = y_max.clamp(0.0, h);
        if y_min > y_max {
            None
        } else {
            Some((y_min, y_max))
        }
    }
}
