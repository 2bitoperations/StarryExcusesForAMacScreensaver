//! Scene-level data and visual constants. Both the windowed `app` shell
//! and the headless `dump_png` mode pull from here so they render an
//! identical scene.

use rand::{Rng, SeedableRng, rngs::StdRng};

use crate::sprite::SpriteInstance;

/// Background color for the scene. Deep night-sky blue — slightly off
/// black so later additive sprite blends have something to read against.
pub const CLEAR_COLOR: wgpu::Color = wgpu::Color {
    r: 0.012,
    g: 0.012,
    b: 0.025,
    a: 1.0,
};

/// Number of star sprites the default scene generates.
pub const STAR_COUNT: usize = 1000;

/// Seed for the default star generator. A fixed seed makes the scene
/// deterministic across launches — essential for the headless PNG dump
/// path and for future visual-diff testing.
pub const STAR_SEED: u64 = 42;

/// Upper bound on simultaneous sprites the renderer is sized for. Comfortably
/// above `STAR_COUNT` to leave room for building lights, shooting stars,
/// satellites, and planet moon dots in later phases.
pub const SPRITE_CAPACITY: u64 = 8192;

/// Default canvas size for both the windowed shell at startup and the
/// headless renderer. Pinned so the PNG dump matches what a fresh window
/// would show.
pub const DEFAULT_WIDTH: u32 = 1280;
pub const DEFAULT_HEIGHT: u32 = 800;

/// Generate the Phase 1 default star field — `STAR_COUNT` uniformly placed
/// white dots with small random radii, seeded by `STAR_SEED` so the output
/// is byte-stable across runs.
pub fn generate_default_stars(width: u32, height: u32) -> Vec<SpriteInstance> {
    let mut rng = StdRng::seed_from_u64(STAR_SEED);
    let w = width as f32;
    let h = height as f32;
    let stars: Vec<SpriteInstance> = (0..STAR_COUNT)
        .map(|_| {
            let x = rng.gen_range(0.0..w);
            let y = rng.gen_range(0.0..h);
            let size = rng.gen_range(1.2..2.6);
            SpriteInstance::new([x, y], size, [1.0, 1.0, 1.0, 1.0])
        })
        .collect();
    log::info!("generated {} stars (seed={})", stars.len(), STAR_SEED);
    stars
}
