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

use std::fmt::Write;
use std::time::{Instant, SystemTime};

use rand::{Rng, SeedableRng, rngs::StdRng};

use crate::config::{
    BUILD_COMMIT, Config, PLANET_BRIGHT_BRIGHTNESS, PLANET_DARK_BRIGHTNESS,
    PLANET_TERMINATOR_BANDS, PLANET_TERMINATOR_WIDTH, PlanetPhaseMode, RingStyle,
};
use crate::cpu_sample::sample_process_cpu_seconds;
use crate::debug_overlay::DebugOverlayFrame;
use crate::moon::{Moon, MoonParams, radius_from_percent};
use crate::planet::{Planet, PlanetIdentity, PlanetParams, moon_sprite_states};
use crate::satellites::SatellitesRenderer;
use crate::shooting_stars::{ShootingStarDirectionMode, ShootingStarsRenderer};
use crate::skyline::Skyline;
use crate::skyline_renderer::SkylineRenderer;
use crate::sprite::SpriteInstance;
use crate::types::debug_moon_color_premul;

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

/// FPS + CPU% smoothers for the Phase 6b debug overlay. EMA constants and
/// FPS-window length mirror `StarryEngine.swift::updateFPS` (`0.6 * prev +
/// 0.4 * fresh` over a 500ms accumulation window) and `sampleCPU` (`0.8 *
/// prev + 0.2 * fresh` every frame). `last_cpu_seconds` is `None` until the
/// first CPU sample lands (matches Swift's `== 0` first-sample guard).
struct DebugSmoothers {
    fps_frame_count: u32,
    fps_accumulated_time: f64,
    current_fps: f64,
    current_cpu_percent: f64,
    last_cpu_seconds: Option<f64>,
    /// Pre-allocated buffer reused every frame; avoids a `format!` heap
    /// allocation on the hot path. Cleared and refilled in `frame_impl`.
    stats_buf: String,
}

impl DebugSmoothers {
    fn new() -> Self {
        Self {
            fps_frame_count: 0,
            fps_accumulated_time: 0.0,
            current_fps: 0.0,
            current_cpu_percent: 0.0,
            last_cpu_seconds: None,
            stats_buf: String::with_capacity(32),
        }
    }

    fn update(&mut self, dt: f64) {
        if dt <= 0.0 {
            return;
        }

        self.fps_frame_count += 1;
        self.fps_accumulated_time += dt;
        if self.fps_accumulated_time >= 0.5 {
            let fps = self.fps_frame_count as f64 / self.fps_accumulated_time;
            self.current_fps = self.current_fps * 0.6 + fps * 0.4;
            self.fps_accumulated_time = 0.0;
            self.fps_frame_count = 0;
        }

        if let Some(cpu_seconds) = sample_process_cpu_seconds() {
            match self.last_cpu_seconds {
                None => {
                    self.last_cpu_seconds = Some(cpu_seconds);
                }
                Some(prev) => {
                    let delta_cpu = (cpu_seconds - prev).max(0.0);
                    let percent = (delta_cpu / dt) * 100.0;
                    self.current_cpu_percent = self.current_cpu_percent * 0.8 + percent * 0.2;
                    self.last_cpu_seconds = Some(cpu_seconds);
                }
            }
        }
    }

    fn refresh_stats_buf(&mut self) {
        self.stats_buf.clear();
        write!(
            &mut self.stats_buf,
            "FPS={:.1} CPU={:.1}%",
            self.current_fps, self.current_cpu_percent
        )
        .expect("write! to String is infallible");
    }
}

/// Everything the GPU layer needs to render one frame. Skyline is the
/// persist-and-wipe layer (single sprite stream + boolean wipe trigger);
/// flasher, satellites, and shooting are `Option`-wrapped decay-in-place
/// layers (presence ⇔ the layer's `*_enabled` / non-zero-period config flag).
pub struct FrameOutput<'a> {
    pub skyline_sprites: &'a [SpriteInstance],
    pub clear_skyline: bool,
    /// Flasher (warning beacon on the tallest building) sprites for this
    /// frame. `Some` iff `config.flasher_period_s > 0`. At most one sprite
    /// (the beacon disc) when ON, zero sprites when OFF — the OFF half is
    /// rendered by the decay layer fading the previous ON frame's pixels.
    /// See `gpu.rs` flasher slot for the rendering pipeline.
    pub flasher: Option<LayerFrame<'a>>,
    pub satellites: Option<LayerFrame<'a>>,
    pub shooting: Option<LayerFrame<'a>>,
    /// Moon parameters for this frame. `Some` iff `config.moon_enabled`
    /// (set at engine construction). Consumed by `MoonRenderer` inside
    /// the composite pass — see `gpu.rs`.
    pub moon: Option<MoonParams>,
    /// Planet draw list for this frame: one `(identity, params)` tuple per
    /// visible planet. Empty when `config.planets_enabled = false`, or when
    /// every planet is hidden by Hide-mode below-horizon filtering. The
    /// identity is needed by `PlanetRenderer::ensure_planet` for texture
    /// cache lookup (Phase 5a Step 7).
    pub planets: &'a [(PlanetIdentity, PlanetParams)],
    /// Planet-moon point sprites (Galilean moons orbiting Jupiter; Titan
    /// orbiting Saturn). Empty when `config.planet_moons_enabled = false`,
    /// when no Jupiter/Saturn parent is visible, or when every moon is
    /// z-culled behind its parent body. Rendered with `BlendMode::Over`
    /// after the planets pass and before the moon pass — see `gpu.rs` /
    /// `headless.rs` for the per-frame draw order.
    pub planet_moons: &'a [SpriteInstance],
    /// Phase 6b debug overlay (FPS/CPU stats + build commit). `Some` iff
    /// `config.debug_overlay_enabled` was true at engine construction.
    /// Borrows `stats_text` from `DebugSmoothers::stats_buf` (pre-allocated,
    /// refilled each frame via `write!`) and `build_info_text` from the
    /// `BUILD_COMMIT` `&'static str` — zero per-frame heap allocation.
    pub debug_overlay: Option<DebugOverlayFrame<'a>>,
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
    /// Planet simulations. Empty when `config.planets_enabled` was false at
    /// construction; otherwise holds all 8 planets in `PlanetIdentity::ALL`
    /// order. Each `Planet` is pure-data (orbital math + spawn-box state); GPU
    /// resources live in `PlanetRenderer` (Phase 5a Step 7).
    planets: Vec<Planet>,
    /// Per-frame scratch buffer for `FrameOutput.planets`. Reused across
    /// frames so we don't reallocate; cleared and refilled in `frame_impl`.
    planet_params_buf: Vec<(PlanetIdentity, PlanetParams)>,
    /// Per-frame scratch buffer for `FrameOutput.flasher.sprites`. Capacity
    /// 1 because the flasher emits exactly one sprite per ON frame (zero
    /// per OFF frame). Reused across frames so we don't reallocate.
    flasher_sprite_buf: Vec<SpriteInstance>,
    /// Per-frame scratch buffer for `FrameOutput.planet_moons`. Capacity 5
    /// because the planet-moons set is exactly Io + Europa + Ganymede +
    /// Callisto + Titan when both parents are visible. Reused across frames.
    planet_moons_sprite_buf: Vec<SpriteInstance>,
    /// Phase 6b debug-overlay smoothers. `Some` iff `config.debug_overlay_enabled`
    /// at construction; skipping construction when disabled keeps zero
    /// per-frame work for the disabled case (no `sample_process_cpu_seconds`
    /// syscall, no string formatting).
    debug_smoothers: Option<DebugSmoothers>,
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

        // Planet construction lives at the END of the RNG-consuming chain so
        // `--planets-enabled false` produces byte-identical output to a build
        // without the planet feature at all: zero RNG drift for the existing
        // skyline / shooting / satellites / moon layers, zero new draws.
        let planets: Vec<Planet> = if config.planets_enabled {
            let nonce: u64 = rng.r#gen();
            PlanetIdentity::ALL
                .iter()
                .map(|&identity| {
                    let size_fraction = planet_size_fraction(identity, &config);
                    let radius = ((config.width as f64 * size_fraction / 2.0) as i32).max(1);
                    Planet::new(
                        identity,
                        config.width as i32,
                        config.height as i32,
                        skyline.building_max_height,
                        radius,
                        config.planet_below_horizon_behavior,
                        nonce,
                    )
                })
                .collect()
        } else {
            Vec::new()
        };

        Self {
            skyline,
            skyline_renderer: SkylineRenderer::new(),
            satellites_renderer,
            shooting_renderer,
            moon,
            planets,
            planet_params_buf: Vec::with_capacity(8),
            flasher_sprite_buf: Vec::with_capacity(1),
            planet_moons_sprite_buf: Vec::with_capacity(5),
            debug_smoothers: config.debug_overlay_enabled.then(DebugSmoothers::new),
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
    /// clock. Used by:
    ///   * The headless PNG dump path, so output is deterministic across
    ///     machines (anchored to `HEADLESS_NOW_UNIX_SECS` + fixed dt).
    ///   * The Phase 6c windowed `deterministic` / `frozen` time modes,
    ///     where `app.rs` computes `wall_now = anchor + frame × fixed_dt`
    ///     (deterministic) or `wall_now = anchor`, `dt = 0` (frozen).
    ///   * Unit tests that want a repeatable simulation step.
    ///
    /// The caller is trusted to supply a sensible `dt` — no
    /// `MAX_DT_SECONDS` clamp here (the clamp exists in `frame()` only to
    /// defang wall-clock hiccups like debugger pauses). Negative dt is
    /// floored to zero.
    ///
    /// `wall_now` is the wall-clock anchor for clock-driven layers (moon,
    /// planets). Headless passes a fixed reference time to keep PNG
    /// output byte-stable across machines.
    pub fn frame_with_dt(&mut self, dt_seconds: f64, wall_now: SystemTime) -> FrameOutput<'_> {
        // `last_frame` is reset to now so that any hypothetical subsequent
        // call to `frame()` (wall-clock dt) sees a ~0 dt rather than the
        // entire elapsed time since construction. In practice time_mode is
        // fixed at config time, so `frame()` and `frame_with_dt()` are never
        // mixed on the same `Engine` instance.
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
        let skyline_sprites =
            self.skyline_renderer
                .frame(&mut self.skyline, dt, &self.config, &mut self.rng);

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

        let flasher = if self.config.flasher_period_s > 0.0 {
            self.flasher_sprite_buf.clear();
            let flasher_radius = self.skyline.flasher_radius;
            if let Some(p) = self.skyline.flasher_state() {
                let diameter = (flasher_radius * 2).max(1) as f32;
                let cx = p.x as f32 + 0.5;
                let cy = p.y as f32 + 0.5;
                self.flasher_sprite_buf.push(SpriteInstance::new(
                    [cx, cy],
                    diameter,
                    p.color.premul_rgba(1.0),
                ));
            }
            let half_life = self.config.flasher_decay_half_life_s;
            let keep_factor = if half_life > 0.0 {
                (0.5_f64.powf(dt / half_life as f64) as f32).clamp(0.0, 1.0)
            } else {
                0.0
            };
            Some(LayerFrame {
                sprites: &self.flasher_sprite_buf,
                keep_factor,
            })
        } else {
            None
        };

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

        self.planet_params_buf.clear();
        self.planet_moons_sprite_buf.clear();
        for planet in &self.planets {
            let state = planet.frame_state(wall_now);
            if state.brightness <= 0.0 {
                continue;
            }
            let phase_fraction = match self.config.planet_phase_mode {
                PlanetPhaseMode::ForcedFull => 1.0,
                PlanetPhaseMode::ForcedHalf => 0.5,
                PlanetPhaseMode::Computed => state.phase_fraction as f32,
            };
            let is_saturn = planet.identity == PlanetIdentity::Saturn;
            let texture_aspect = if is_saturn { 2.0 } else { 1.0 };
            let ring_style = if is_saturn {
                i32::from(self.config.saturn_ring_style)
            } else {
                i32::from(RingStyle::Smooth)
            };
            let ring_tilt_deg = if is_saturn {
                self.config
                    .saturn_ring_tilt_angle
                    .unwrap_or(state.ring_tilt_deg) as f32
            } else {
                state.ring_tilt_deg as f32
            };
            let ring_rotation_deg = if is_saturn {
                self.config
                    .saturn_ring_rotation_angle
                    .unwrap_or(state.ring_rotation_deg) as f32
            } else {
                state.ring_rotation_deg as f32
            };
            self.planet_params_buf.push((
                planet.identity,
                PlanetParams {
                    center_px: [state.center_px.0 as f32, state.center_px.1 as f32],
                    radius_px: planet.radius as f32,
                    phase_fraction,
                    bright_brightness: PLANET_BRIGHT_BRIGHTNESS,
                    dark_brightness: PLANET_DARK_BRIGHTNESS,
                    waxing_sign: state.waxing_sign as f32,
                    terminator_mode: self.config.planet_terminator_mode as i32,
                    terminator_width: PLANET_TERMINATOR_WIDTH,
                    terminator_bands: PLANET_TERMINATOR_BANDS as i32,
                    texture_aspect,
                    ring_tilt_deg,
                    ring_rotation_deg,
                    ring_style,
                },
            ));

            if !self.config.planet_moons_enabled {
                continue;
            }
            let moon_scale = match planet.identity {
                PlanetIdentity::Jupiter => self.config.jupiter_moon_scale,
                PlanetIdentity::Saturn => self.config.saturn_moon_scale,
                _ => continue,
            };
            let body_radius_px = if is_saturn {
                planet.radius as f64 * 0.846
            } else {
                planet.radius as f64
            };
            let debug_colors = self.config.debug_moon_colors;
            moon_sprite_states(
                planet.identity,
                wall_now,
                state.center_px,
                body_radius_px,
                ring_tilt_deg as f64,
                ring_rotation_deg as f64,
                moon_scale,
                |m| {
                    let color = if debug_colors {
                        debug_moon_color_premul(m.name)
                            .unwrap_or_else(|| m.color.premul_rgba(m.alpha))
                    } else {
                        m.color.premul_rgba(m.alpha)
                    };
                    self.planet_moons_sprite_buf.push(SpriteInstance::new(
                        [m.center_px.0 as f32, m.center_px.1 as f32],
                        m.size_px,
                        color,
                    ));
                },
            );
        }

        if let Some(s) = self.debug_smoothers.as_mut() {
            s.update(dt);
            s.refresh_stats_buf();
        }
        let debug_overlay = self.debug_smoothers.as_ref().map(|s| DebugOverlayFrame {
            stats_text: &s.stats_buf,
            build_info_text: BUILD_COMMIT,
        });
        FrameOutput {
            skyline_sprites,
            clear_skyline,
            flasher,
            satellites,
            shooting,
            moon,
            planets: &self.planet_params_buf,
            planet_moons: &self.planet_moons_sprite_buf,
            debug_overlay,
        }
    }
}

fn planet_size_fraction(identity: PlanetIdentity, config: &Config) -> f64 {
    match identity {
        PlanetIdentity::Mercury => config.mercury_size,
        PlanetIdentity::Venus => config.venus_size,
        PlanetIdentity::Mars => config.mars_size,
        PlanetIdentity::Jupiter => config.jupiter_size,
        PlanetIdentity::Saturn => config.saturn_size,
        PlanetIdentity::Uranus => config.uranus_size,
        PlanetIdentity::Neptune => config.neptune_size,
        PlanetIdentity::Pluto => config.pluto_size,
    }
}
