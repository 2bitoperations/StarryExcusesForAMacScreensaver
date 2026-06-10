//! Runtime configuration + visual constants. Sourced from CLI flags (clap-
//! derive) or defaults; the defaults mirror
//! [`StarryDefaultsManager.swift`](../../StarryExcuseForAMacScreensaver/StarryDefaultsManager.swift)
//! so the Rust port reproduces the Swift "fresh install" look. Only Phase-2
//! flags are exposed here — later phases will add their own.

use std::path::PathBuf;

use clap::Parser;

/// Sky color cleared into the composite target every frame. Opaque black
/// to match Swift (`StarryMetalRenderer.swift:1593` —
/// `MTLClearColorMake(0, 0, 0, 1)`). The persistent skyline layer's empty
/// regions are transparent (see `LAYER_WIPE_COLOR`) and get blended over
/// this background each frame, so this is what the user sees behind the
/// sprites.
pub const CLEAR_COLOR: wgpu::Color = wgpu::Color {
    r: 0.0,
    g: 0.0,
    b: 0.0,
    a: 1.0,
};

/// Wipe color used to reset the persistent skyline layer at the start of
/// each persistence cycle. Transparent black so the un-painted regions
/// show through to whatever the composite target was cleared to (i.e.
/// `CLEAR_COLOR`). Mirrors Swift's per-layer `.clear` ops at
/// `StarryMetalRenderer.swift:1859/1991/2221/2319` —
/// `MTLClearColorMake(0, 0, 0, 0)`.
pub const LAYER_WIPE_COLOR: wgpu::Color = wgpu::Color {
    r: 0.0,
    g: 0.0,
    b: 0.0,
    a: 0.0,
};

// Reference screen size + max-per-second rates Swift uses to anchor the
// 0..1 fraction sliders. Any other resolution scales linearly by area
// — source: StarryConfigSheetController.swift lines 209-212.
const REFERENCE_W: f64 = 3008.0;
const REFERENCE_H: f64 = 1692.0;
const MAX_STARS_PER_SEC_AT_REF: f64 = 1600.0;
const MAX_LIGHTS_PER_SEC_AT_REF: f64 = 600.0;

/// Upper bound on simultaneous sprites the GPU instance buffer is sized
/// for. Phase 2 emits only NEW sprites per frame (typically < 20), so this
/// is generous headroom for first-frame bursts when `dt` is unusually
/// large, plus runway for the multi-layer phases.
pub const SPRITE_CAPACITY: u64 = 131_072;

#[derive(Debug, Clone, Parser)]
#[command(
    version,
    about = "starry-rs — Rust+wgpu port of the Starry Night screensaver"
)]
pub struct Config {
    /// Width of the window / dump in pixels.
    #[arg(long, default_value_t = 1280)]
    pub width: u32,

    /// Height of the window / dump in pixels.
    #[arg(long, default_value_t = 800)]
    pub height: u32,

    /// If set, render one frame to this PNG path and exit instead of
    /// opening a window.
    #[arg(long)]
    pub dump_png: Option<PathBuf>,

    /// Star emission rate as a fraction of the reference max. Swift default
    /// (`starsPerUpdateFraction`) is 0.5.
    #[arg(long, default_value_t = 0.5)]
    pub stars_fraction: f64,

    /// Building-light emission rate as a fraction of the reference max.
    /// Swift default (`buildingLightsPerUpdateFraction`) is 0.25.
    #[arg(long, default_value_t = 0.25)]
    pub lights_fraction: f64,

    /// Seconds between full-canvas wipes. Swift default is 120.
    #[arg(long, default_value_t = 120.0)]
    pub clear_interval_s: f64,

    /// Max building height as a fraction of screen height. Swift default 0.35.
    #[arg(long, default_value_t = 0.35)]
    pub building_height_pct_max: f64,

    /// Building width range, inclusive lower bound. Swift default 40.
    #[arg(long, default_value_t = 40)]
    pub building_width_min: i32,

    /// Building width range, exclusive upper bound. Swift default 300
    /// (expressed as the inclusive form `40...299` in the original).
    #[arg(long, default_value_t = 300)]
    pub building_width_max: i32,

    /// Approximate count of buildings per pixel of width. Swift default 0.033
    /// ≈ 1 building per 30 columns; on a 3000-px-wide screen ≈ 100 buildings.
    #[arg(long, default_value_t = 0.033)]
    pub building_frequency: f64,

    /// Flasher disc radius in pixels. Set to 0 to hide it entirely.
    #[arg(long, default_value_t = 4)]
    pub flasher_radius: i32,

    /// Flasher animation period in seconds. On for the first half of the
    /// period, off for the second half. Set to 0 to leave it always on.
    #[arg(long, default_value_t = 2.0)]
    pub flasher_period_s: f64,

    /// RNG seed for deterministic building/star layout. Defaults to a
    /// fixed value so headless dumps are reproducible across runs.
    #[arg(long, default_value_t = 42)]
    pub seed: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self::try_parse_from(["starry-rs"]).expect("default config must parse")
    }
}

/// Convert a 0..1 emission fraction into sprites-per-second, scaling by
/// screen area so a tiny preview window gets proportionally fewer sprites
/// than the reference resolution.
pub fn scaled_rate(
    fraction: f64,
    max_at_ref: f64,
    width: i32,
    height: i32,
) -> f64 {
    let area = (width as f64) * (height as f64);
    let ref_area = REFERENCE_W * REFERENCE_H;
    fraction.max(0.0) * max_at_ref * (area / ref_area)
}

pub fn stars_per_second(cfg: &Config, width: i32, height: i32) -> f64 {
    scaled_rate(cfg.stars_fraction, MAX_STARS_PER_SEC_AT_REF, width, height)
}

pub fn lights_per_second(cfg: &Config, width: i32, height: i32) -> f64 {
    scaled_rate(cfg.lights_fraction, MAX_LIGHTS_PER_SEC_AT_REF, width, height)
}
