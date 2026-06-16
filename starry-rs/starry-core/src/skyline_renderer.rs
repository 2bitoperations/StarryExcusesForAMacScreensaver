//! Per-frame sprite emitter for the skyline layer. Reads `Skyline` state +
//! a configurable per-second rate, returns only the **new** sprites born
//! this frame (the persistent skyline texture on the GPU side accumulates
//! everything historical, so this layer never has to re-emit old pixels).
//!
//! Time-accumulator pattern mirrors `SkylineCoreRenderer.swift:142-148` —
//! `acc += rate * dt; n = floor(acc); acc -= n` keeps fractional emission
//! debt across frames so the long-run rate stays exact even at variable dt.
//!
//! NOTE: the flasher (warning beacon) is intentionally NOT emitted here.
//! It lives on its own decay-in-place layer (see `gpu.rs` flasher slot)
//! so the OFF half of its blink cycle can fade out cleanly via the decay
//! shader. Baking it into the persistent skyline texture (the pre-fix
//! design) would leave a permanently-lit red dot during every OFF half.
//! The flasher sprite is emitted by `Engine::frame_impl` directly into
//! `FrameOutput.flasher`.

use rand::Rng;

use crate::config::{lights_per_second, stars_per_second, Config};
use crate::skyline::Skyline;
use crate::sprite::SpriteInstance;
use crate::types::Point;

/// Sprite size (pixels) used for the 1-px-style point lights. The disc
/// shader needs a non-zero radius to draw something visible; 1.5 keeps
/// the dot crisp without bleeding into adjacent pixels.
const POINT_SPRITE_SIZE: f32 = 1.5;

pub struct SkylineRenderer {
    star_acc: f64,
    light_acc: f64,
    sprites: Vec<SpriteInstance>,
}

impl SkylineRenderer {
    pub fn new() -> Self {
        Self {
            star_acc: 0.0,
            light_acc: 0.0,
            sprites: Vec::with_capacity(64),
        }
    }

    /// Emit this frame's new sprites. Returns a slice borrow into an
    /// internal buffer reused across calls.
    pub fn frame<R: Rng + ?Sized>(
        &mut self,
        skyline: &mut Skyline,
        dt_seconds: f64,
        config: &Config,
        rng: &mut R,
    ) -> &[SpriteInstance] {
        self.sprites.clear();

        let star_rate =
            stars_per_second(config, skyline.width, skyline.height);
        self.star_acc += star_rate * dt_seconds;
        let star_attempts = self.star_acc.floor() as i32;
        self.star_acc -= star_attempts as f64;

        for _ in 0..star_attempts.max(0) {
            if let Some(p) = skyline.attempt_star(rng) {
                self.sprites.push(point_to_sprite(p, POINT_SPRITE_SIZE));
            }
        }

        let light_rate =
            lights_per_second(config, skyline.width, skyline.height);
        self.light_acc += light_rate * dt_seconds;
        let light_count = self.light_acc.floor() as i32;
        self.light_acc -= light_count as f64;

        for _ in 0..light_count.max(0) {
            if let Some(p) = skyline.sample_building_light(rng) {
                self.sprites.push(point_to_sprite(p, POINT_SPRITE_SIZE));
            }
        }

        &self.sprites
    }
}

impl Default for SkylineRenderer {
    fn default() -> Self {
        Self::new()
    }
}

/// Convert a logical `Point` into a `SpriteInstance` ready for the GPU.
/// Matches `SkylineCoreRenderer.swift:204-210` — half-pixel offset
/// centers the sprite on the integer pixel coordinate.
fn point_to_sprite(p: Point, size_pixels: f32) -> SpriteInstance {
    let cx = p.x as f32 + 0.5;
    let cy = p.y as f32 + 0.5;
    SpriteInstance::new([cx, cy], size_pixels, p.color.premul_rgba(1.0))
}
