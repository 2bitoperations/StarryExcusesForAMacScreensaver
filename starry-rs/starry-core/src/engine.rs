//! The simulation orchestrator. Owns the static skyline, the per-layer
//! emitters, the seeded RNG, the dt clock, and surfaces the per-frame
//! signals the GPU layer needs:
//!
//! - **Skyline layer** (persist-and-wipe): new sprites this frame + a
//!   `clear_skyline` flag (true once every `clear_interval_s` seconds).
//! - **Satellites layer** (decay-in-place): `LayerFrame { sprites,
//!   keep_factor }` — sprites are blended into the persistent satellites
//!   texture, and the existing pixels are multiplied by `keep_factor`
//!   each frame so old positions fade exponentially.
//! - **Shooting-stars layer** (decay-in-place): same shape as satellites.
//! - **Moon layer** (draw-on-top): a single `MoonParams` snapshot computed
//!   from the engine's clock (wall time threaded in via `frame(wall_now)`),
//!   consumed by `moon_renderer::MoonRenderer` inside the composite pass.
//!
//! All three optional layers (`Option<LayerFrame>` for satellites/shooting,
//! `Option<MoonParams>` for moon) are gated on their respective
//! `*_enabled` config flag: when disabled the simulation skips the work
//! and the corresponding `FrameOutput` field is `None`, so the GPU layer
//! can skip the matching passes entirely (no wasted work for disabled
//! features).
//!
//! Rust counterpart of `StarryEngine.swift`.

use std::time::{Instant, SystemTime};

use rand::{rngs::StdRng, SeedableRng};

use crate::config::Config;
use crate::moon::{radius_from_percent, Moon, MoonParams};
use crate::satellites::SatellitesRenderer;
use crate::shooting_stars::{ShootingStarDirectionMode, ShootingStarsRenderer};
use crate::skyline::Skyline;
use crate::skyline_renderer::SkylineRenderer;
use crate::sprite::SpriteInstance;

/// Maximum dt clamp (seconds). Long pauses (debugger break, system sleep)
/// would otherwise burst-emit thousands of sprites in one frame; clamping
/// keeps the simulation visually well-behaved across hiccups.
const MAX_DT_SECONDS: f64 = 0.25;

/// Per-decay-layer output: new sprites to draw this frame + the multiplier
/// to apply to the layer's existing pixels (the "decay" step). `1.0` =
/// no fade, `0.0` = wipe to transparent every frame, in between =
/// exponential fade with half-life = `trail_half_life_s` config value.
pub struct LayerFrame<'a> {
    pub sprites: &'a [SpriteInstance],
    pub keep_factor: f32,
}

/// Everything the GPU layer needs to render one frame. Skyline is the
/// persist-and-wipe layer (single sprite stream + boolean wipe trigger);
/// satellites and shooting are `Option`-wrapped decay-in-place layers
/// (renderer presence ⇔ the layer's `*_enabled` config flag).
pub struct FrameOutput<'a> {
    pub skyline_sprites: &'a [SpriteInstance],
    pub clear_skyline: bool,
    pub satellites: Option<LayerFrame<'a>>,
    pub shooting: Option<LayerFrame<'a>>,
    /// Moon parameters for this frame. `Some` iff `config.moon_enabled`
    /// (set at engine construction). Consumed by `MoonRenderer` inside
    /// the composite pass — see `gpu.rs`.
    pub moon: Option<MoonParams>,
}

pub struct Engine {
    skyline: Skyline,
    skyline_renderer: SkylineRenderer,
    satellites_renderer: Option<SatellitesRenderer>,
    shooting_renderer: Option<ShootingStarsRenderer>,
    /// Moon simulation. `Some` iff `config.moon_enabled` at construction.
    /// Owns its arch geometry but not its GPU resources (those live in
    /// `MoonRenderer` in the GPU layer — Engine produces pure data).
    moon: Option<Moon>,
    config: Config,
    rng: StdRng,
    last_frame: Instant,
}

impl Engine {
    pub fn new(config: Config) -> Self {
        let mut rng = StdRng::seed_from_u64(config.seed);
        let skyline = Skyline::new(
            config.width as i32,
            config.height as i32,
            config.building_height_pct_max,
            config.building_width_min,
            config.building_width_max,
            config.building_frequency,
            config.flasher_radius,
            config.flasher_period_s,
            config.clear_interval_s,
            &mut rng,
        );

        let shooting_renderer = config.shooting_stars_enabled.then(|| {
            ShootingStarsRenderer::new(
                config.width as i32,
                config.height as i32,
                skyline.building_max_height,
                config.shooting_stars_avg_seconds,
                ShootingStarDirectionMode::from_int(config.shooting_stars_direction_mode),
                config.shooting_stars_length,
                config.shooting_stars_speed,
                config.shooting_stars_thickness,
                config.shooting_stars_brightness,
                config.shooting_stars_trail_half_life_s,
            )
        });

        let satellites_renderer = config.satellites_enabled.then(|| {
            // Both flasher params are Some-or-both-None per the SatellitesRenderer
            // contract. `skyline.flasher_pos` is None when the skyline has no
            // flasher (radius=0 or no buildings tall enough), and the renderer
            // then falls back to the full default vertical band.
            let flasher_y = skyline.flasher_pos.map(|p| p.y as f32);
            let flasher_r = skyline.flasher_pos.map(|_| skyline.flasher_radius as f32);
            SatellitesRenderer::new(
                config.width as i32,
                config.height as i32,
                config.satellites_avg_spawn_seconds,
                config.satellites_speed,
                config.satellites_size,
                config.satellites_brightness,
                config.satellites_trailing,
                config.satellites_trail_half_life_s,
                flasher_y,
                flasher_r,
                &mut rng,
            )
        });

        // Moon construction: derive radius from viewport width + percent
        // (same formula `MoonRenderer::resize` uses, so engine and GPU
        // agree on size) and pass the skyline's tallest building down so
        // the arch baseline never clips the silhouette.
        let moon = config.moon_enabled.then(|| {
            let radius = radius_from_percent(config.width as i32, config.moon_diameter_percent);
            Moon::new(
                config.width as i32,
                config.height as i32,
                skyline.building_max_height,
                radius,
                config.moon_traversal_seconds,
                config.moon_phase_override_enabled,
                config.moon_phase_override_value,
                &mut rng,
            )
        });

        Self {
            skyline,
            skyline_renderer: SkylineRenderer::new(),
            satellites_renderer,
            shooting_renderer,
            moon,
            config,
            rng,
            last_frame: Instant::now(),
        }
    }

    pub fn width(&self) -> u32 {
        self.config.width
    }

    pub fn height(&self) -> u32 {
        self.config.height
    }

    /// Advance the simulation by the time elapsed since the previous
    /// `frame()` call and emit this frame's per-layer outputs.
    ///
    /// `wall_now` is the wall-clock time used by clock-driven simulations
    /// (moon position + phase). Threading it in (rather than calling
    /// `SystemTime::now()` internally) keeps headless rendering
    /// deterministic — the headless path passes a fixed reference time.
    pub fn frame(&mut self, wall_now: SystemTime) -> FrameOutput<'_> {
        let instant_now = Instant::now();
        let raw_dt = instant_now.duration_since(self.last_frame).as_secs_f64();
        let dt = raw_dt.clamp(0.0, MAX_DT_SECONDS);
        self.last_frame = instant_now;
        self.frame_impl(dt, wall_now)
    }

    /// Render one frame against an explicit `dt` rather than the wall
    /// clock. Used by the headless PNG dump path so the output is
    /// deterministic across machines, and for tests. The caller is
    /// trusted to supply a sensible `dt` — no `MAX_DT_SECONDS` clamp
    /// here (the clamp exists in `frame()` only to defang wall-clock
    /// hiccups like debugger pauses). Negative dt is floored to zero.
    ///
    /// `wall_now` is the wall-clock anchor for clock-driven layers (moon).
    /// Headless passes a fixed reference time to keep PNG output
    /// byte-stable across machines.
    pub fn frame_with_dt(&mut self, dt_seconds: f64, wall_now: SystemTime) -> FrameOutput<'_> {
        self.last_frame = Instant::now();
        self.frame_impl(dt_seconds.max(0.0), wall_now)
    }

    fn frame_impl(&mut self, dt: f64, wall_now: SystemTime) -> FrameOutput<'_> {
        let clear_skyline = self.skyline.should_clear_now();
        if clear_skyline {
            self.skyline.mark_cleared();
        }

        // Each renderer's `frame()` mutates a disjoint field of `self`
        // and returns a slice borrowing from that same disjoint field.
        // NLL handles the three independent borrows cleanly when the
        // FrameOutput is constructed at the end.
        let skyline_sprites = self.skyline_renderer.frame(
            &mut self.skyline,
            dt,
            &self.config,
            &mut self.rng,
        );

        let satellites = self.satellites_renderer.as_mut().map(|r| {
            let f = r.frame(dt, &mut self.rng);
            LayerFrame {
                sprites: f.sprites,
                keep_factor: f.keep_factor,
            }
        });

        let shooting = self.shooting_renderer.as_mut().map(|r| {
            let f = r.frame(dt, &mut self.rng);
            LayerFrame {
                sprites: f.sprites,
                keep_factor: f.keep_factor,
            }
        });

        // Moon is pure data — no &mut borrow of self.moon needed, just
        // a snapshot from the wall clock + config-driven appearance knobs.
        let moon = self.moon.as_ref().map(|m| {
            let state = m.frame_state(wall_now);
            MoonParams::from_frame_state(
                state,
                m.radius() as f32,
                self.config.moon_bright_brightness,
                self.config.moon_dark_brightness,
                self.config.moon_terminator_mode,
                self.config.moon_terminator_width,
                self.config.moon_terminator_bands,
                self.config.debug_moon_colors,
            )
        });

        FrameOutput {
            skyline_sprites,
            clear_skyline,
            satellites,
            shooting,
            moon,
        }
    }
}
