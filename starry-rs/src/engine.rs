//! The simulation orchestrator. Owns the static skyline, the per-frame
//! emitter, the seeded RNG, the dt clock, and surfaces the per-frame
//! signals the GPU layer needs (new sprites + "wipe the layer texture
//! now" flag). Rust counterpart of `StarryEngine.swift`.

use std::time::Instant;

use rand::{rngs::StdRng, SeedableRng};

use crate::config::Config;
use crate::skyline::Skyline;
use crate::skyline_renderer::SkylineRenderer;
use crate::sprite::SpriteInstance;

/// Maximum dt clamp (seconds). Long pauses (debugger break, system sleep)
/// would otherwise burst-emit thousands of sprites in one frame; clamping
/// keeps the simulation visually well-behaved across hiccups.
const MAX_DT_SECONDS: f64 = 0.25;

/// What the GPU layer needs to know each frame: the new sprites to draw
/// and whether to wipe the persistent skyline texture before drawing them.
pub struct FrameOutput<'a> {
    pub sprites: &'a [SpriteInstance],
    pub clear_layer: bool,
}

pub struct Engine {
    skyline: Skyline,
    renderer: SkylineRenderer,
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
        Self {
            skyline,
            renderer: SkylineRenderer::new(),
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
    /// `frame()` call and emit this frame's new sprites.
    pub fn frame(&mut self) -> FrameOutput<'_> {
        let now = Instant::now();
        let raw_dt = now.duration_since(self.last_frame).as_secs_f64();
        let dt = raw_dt.clamp(0.0, MAX_DT_SECONDS);
        self.last_frame = now;

        let clear_layer = self.skyline.should_clear_now();
        if clear_layer {
            self.skyline.mark_cleared();
        }

        let sprites = self.renderer.frame(
            &mut self.skyline,
            dt,
            &self.config,
            &mut self.rng,
        );

        FrameOutput {
            sprites,
            clear_layer,
        }
    }

    /// Render one frame against an explicit `dt` rather than the wall
    /// clock. Used by the headless PNG dump path so the output is
    /// deterministic across machines, and for tests. The caller is
    /// trusted to supply a sensible `dt` — no `MAX_DT_SECONDS` clamp
    /// here (the clamp exists in `frame()` only to defang wall-clock
    /// hiccups like debugger pauses). Negative dt is floored to zero.
    pub fn frame_with_dt(&mut self, dt_seconds: f64) -> FrameOutput<'_> {
        self.last_frame = Instant::now();
        let clear_layer = self.skyline.should_clear_now();
        if clear_layer {
            self.skyline.mark_cleared();
        }
        let sprites = self.renderer.frame(
            &mut self.skyline,
            dt_seconds.max(0.0),
            &self.config,
            &mut self.rng,
        );
        FrameOutput {
            sprites,
            clear_layer,
        }
    }
}
