//! `Skyline` — the static structural world state: a deterministic set of
//! buildings, a per-column "sky floor" (lowest open-sky y at each x), and a
//! flasher perched on the tallest rooftop. This is the Rust port of
//! [`Skyline.swift`](../../StarryExcuseForAMacScreensaver/Skyline.swift).
//!
//! Two **deliberate** departures from the Swift original (worth their own
//! callouts since they're easy to mistake for porting bugs):
//!
//! 1. `attempt_star` is single-shot — it returns `Option<Point>` from one
//!    sample rather than looping until a sample lands above the skyline.
//!    The renderer calls it N times per frame and keeps what passes. Per
//!    user request this decouples star density from building density: more
//!    buildings → fewer accepted stars, never a slower frame.
//!
//! 2. `sample_building_light` has a finite attempt cap (defensive — Swift
//!    loops until success, which is fine when buildings reliably exist; a
//!    cap prevents a degenerate "no buildings at all" config from spinning
//!    forever).
//!
//! Off-by-one alignment with Swift is preserved exactly (Oracle flagged
//! these and we want bit-for-bit parity where possible):
//! * `sky_floor` length is `screen_width + 1` (one past the last column).
//! * Building generation runs `0..=computed_count` (inclusive) — produces
//!   `count + 1` buildings, matching Swift.
//! * Star sampling uses `0..=width` for x (one past last column); light
//!   sampling uses `0..width` (exclusive). Yes, the asymmetry is real and
//!   intentional in the Swift source.

use std::time::{Duration, Instant};

use rand::Rng;

use crate::buildings::{
    Building, BUILDING_COLOR, BUILDING_STYLES, FLASHER_COLOR,
};
use crate::types::{random_star_color, Point};

/// Default cap on per-call retries when hunting for a lit building window.
/// Swift loops forever; we cap it so a degenerate "zero buildings" config
/// can't lock the frame loop.
const LIGHT_SAMPLE_MAX_ATTEMPTS: u32 = 200;

pub struct Skyline {
    pub width: i32,
    pub height: i32,
    pub buildings: Vec<Building>,
    sky_floor: Vec<i32>,

    /// Cap on building height in pixels (Swift `buildingMaxHeight` —
    /// `screenHeight * heightPctMax`, floored to ≥1). Stored so layers
    /// like shooting-stars can place their `safe_min_y` above the tallest
    /// possible rooftop without re-deriving it from the config.
    pub building_max_height: i32,

    pub flasher_pos: Option<Point>,
    pub flasher_radius: i32,
    flasher_period: Duration,
    flasher_period_start: Instant,

    created_at: Instant,
    clear_after: Duration,
}

impl Skyline {
    #[allow(clippy::too_many_arguments)]
    pub fn new<R: Rng + ?Sized>(
        screen_width: i32,
        screen_height: i32,
        building_height_pct_max: f64,
        building_width_min: i32,
        building_width_max: i32,
        building_frequency: f64,
        flasher_radius: i32,
        flasher_period_s: f64,
        clear_after_s: f64,
        rng: &mut R,
    ) -> Self {
        let building_max_height =
            (screen_height as f64 * building_height_pct_max).max(1.0) as i32;

        let computed_count =
            ((screen_width as f64) * building_frequency).max(0.0) as i32;

        let mut buildings: Vec<Building> =
            Vec::with_capacity((computed_count + 1) as usize);

        // Inclusive upper bound matches Swift's `0...computedBuildingCount`.
        for z_index in 0..=computed_count {
            let style_idx = rng.gen_range(0..BUILDING_STYLES.len());
            let height =
                Self::weighted_random_height(rng, building_max_height);

            // Swift: `Int.random(in: 0...screenXMax - 1)`.
            let start_x = rng.gen_range(0..screen_width);

            // Swift: `min(Int.random(in: widthMin...widthMax - 1),
            //              screenXMax - buildingXStart)`. The 0..max
            //  exclusive form in Rust is the same as Swift's `min...max-1`.
            let raw_width = rng.gen_range(building_width_min..building_width_max);
            let width = raw_width.min(screen_width - start_x).max(1);

            buildings.push(Building {
                start_x,
                start_y: 0,
                width,
                height,
                z: z_index,
                style_idx,
            });
        }

        buildings.sort_by_key(|b| b.start_x);

        // Per-column sky floor, one entry past the last column to match
        // Swift's `[Int](repeating: 0, count: max(screenXMax + 1, 1))`.
        let mut sky_floor = vec![0i32; (screen_width + 1).max(1) as usize];
        for b in &buildings {
            let top_y = b.start_y + b.height;
            let end_x = (b.start_x + b.width).min(screen_width + 1);
            for x in b.start_x.max(0)..end_x {
                if top_y > sky_floor[x as usize] {
                    sky_floor[x as usize] = top_y;
                }
            }
        }

        let flasher_pos = Self::compute_flasher_position(
            &buildings,
            flasher_radius,
        );

        let now = Instant::now();
        Skyline {
            width: screen_width,
            height: screen_height,
            buildings,
            sky_floor,
            building_max_height,
            flasher_pos,
            flasher_radius,
            flasher_period: Duration::from_secs_f64(flasher_period_s.max(0.0)),
            flasher_period_start: now,
            created_at: now,
            clear_after: Duration::from_secs_f64(clear_after_s.max(0.0)),
        }
    }

    /// Quadratically weighted toward small values, matching Swift's
    /// `pow(Double.random(in: 0.01...1), 2)` — biases buildings shorter.
    fn weighted_random_height<R: Rng + ?Sized>(
        rng: &mut R,
        max_height: i32,
    ) -> i32 {
        let r: f64 = rng.gen_range(0.01..=1.0);
        let weighted = r * r;
        ((weighted * max_height as f64) as i32).max(1)
    }

    fn compute_flasher_position(
        buildings: &[Building],
        flasher_radius: i32,
    ) -> Option<Point> {
        let tallest = buildings.iter().max_by_key(|b| b.height)?;
        let fx = tallest.start_x + (tallest.width / 2);
        let fy = tallest.start_y + tallest.height + flasher_radius;
        Some(Point::new(fx, fy, FLASHER_COLOR))
    }

    /// Reset the clear-timer baseline. Called by the renderer when it
    /// performs a periodic wipe so we don't immediately request another.
    pub fn mark_cleared(&mut self) {
        self.created_at = Instant::now();
    }

    pub fn should_clear_now(&self) -> bool {
        self.created_at.elapsed() >= self.clear_after
    }

    /// One sample attempt at a horizon-weighted star. Returns `None` when
    /// the sampled y falls below the skyline at that column. **Does not
    /// retry** — caller-driven attempt count by design (see module doc).
    pub fn attempt_star<R: Rng + ?Sized>(
        &self,
        rng: &mut R,
    ) -> Option<Point> {
        if self.height <= 0 {
            return None;
        }
        let h = self.height as f64;

        // Inclusive upper bound matches Swift's `0...self.width`.
        let cx = rng.gen_range(0..=self.width);
        let t: f64 = rng.gen_range(0.0..=1.0);
        let cy = (h * (1.0 - (1.0 - t).sqrt())) as i32;

        let idx = (cx as usize).min(self.sky_floor.len().saturating_sub(1));
        let min_y = self.sky_floor[idx];

        if cy >= min_y {
            Some(Point::new(cx, cy, random_star_color(rng)))
        } else {
            None
        }
    }

    /// Bounded search for a building pixel where the tile mask says the
    /// light is on. Returns `None` if no hit within `LIGHT_SAMPLE_MAX_ATTEMPTS`
    /// (only possible with no buildings or pathologically sparse styles).
    pub fn sample_building_light<R: Rng + ?Sized>(
        &self,
        rng: &mut R,
    ) -> Option<Point> {
        if self.width <= 0 || self.height <= 0 || self.buildings.is_empty() {
            return None;
        }
        for _ in 0..LIGHT_SAMPLE_MAX_ATTEMPTS {
            let x = rng.gen_range(0..self.width);
            let y = rng.gen_range(0..self.height);
            if let Some(b) = self.building_at_point(x, y)
                && b.is_light_on(x, y)
            {
                return Some(Point::new(x, y, BUILDING_COLOR));
            }
        }
        None
    }

    /// Topmost-by-Z building containing the given pixel, mirroring
    /// `Skyline.swift::getBuildingAtPoint`. `buildings` is pre-sorted by
    /// `start_x` so we can break early.
    fn building_at_point(&self, x: i32, y: i32) -> Option<&Building> {
        let mut front: Option<&Building> = None;
        for b in &self.buildings {
            if b.start_x > x {
                break;
            }
            if b.contains(x, y) {
                match front {
                    Some(f) if b.z > f.z => front = Some(b),
                    None => front = Some(b),
                    _ => {}
                }
            }
        }
        front
    }

    /// Flasher on/off state for this instant. Swift's animation: on for
    /// the first half of `flasher_period`, off for the second half, then
    /// the period restarts. We emit `Some(pos)` when on, `None` when off
    /// (or when the period is zero, i.e. flasher is disabled, or when
    /// there is no flasher position to flash at).
    ///
    /// Consumed by the per-frame flasher sprite emitter in
    /// `Engine::frame_impl`, NOT by `SkylineRenderer` — the flasher lives
    /// on its own decay layer (see `gpu.rs::DecayLayer` flasher slot) so
    /// the OFF half can fade out cleanly. If we baked it into the
    /// persistent skyline texture (Phase 2 design), the OFF-half `None`
    /// would leave the previously-drawn red dot sitting there forever,
    /// making the flasher appear permanently lit.
    pub fn flasher_state(&mut self) -> Option<Point> {
        let pos = self.flasher_pos?;
        if self.flasher_period.is_zero() {
            return None;
        }
        let elapsed = self.flasher_period_start.elapsed();
        if elapsed < self.flasher_period / 2 {
            Some(pos)
        } else if elapsed < self.flasher_period {
            None
        } else {
            // Period rolled over — restart so the next call lights up.
            self.flasher_period_start = Instant::now();
            Some(pos)
        }
    }
}
