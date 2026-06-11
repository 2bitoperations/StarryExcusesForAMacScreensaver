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

    // ---- Phase 3: shooting stars ----
    /// Enable the shooting-stars layer. Swift default
    /// (`defaultShootingStarsEnabled`) is `true`.
    #[arg(long, action = clap::ArgAction::Set, default_value_t = true)]
    pub shooting_stars_enabled: bool,

    /// Mean seconds between shooting-star spawn attempts (per-frame
    /// Bernoulli with p = dt/avg). Swift default
    /// (`defaultShootingStarsAvgSeconds`) is 7.0.
    #[arg(long, default_value_t = 7.0)]
    pub shooting_stars_avg_seconds: f64,

    /// Direction mode: 0=Random, 1=LeftToRight, 2=RightToLeft,
    /// 3=TopLeftToBottomRight, 4=TopRightToBottomLeft. Unknown values
    /// fall back to Random. Swift default
    /// (`defaultShootingStarsDirectionMode`) is 0.
    #[arg(long, default_value_t = 0)]
    pub shooting_stars_direction_mode: i32,

    /// Base streak length in pixels (randomized ±15% per spawn). Swift
    /// default (`defaultShootingStarsLength`) is 160.
    #[arg(long, default_value_t = 160.0)]
    pub shooting_stars_length: f32,

    /// Streak speed in pixels/second. Lifetime = length / speed. Swift
    /// default (`defaultShootingStarsSpeed`) is 600.
    #[arg(long, default_value_t = 600.0)]
    pub shooting_stars_speed: f32,

    /// Streak thickness in pixels (head sprite size). Swift default
    /// (`defaultShootingStarsThickness`) is 2.
    #[arg(long, default_value_t = 2.0)]
    pub shooting_stars_thickness: f32,

    /// Streak brightness multiplier in [0, 1]. Swift default
    /// (`defaultShootingStarsBrightness`) is 0.2.
    #[arg(long, default_value_t = 0.2)]
    pub shooting_stars_brightness: f32,

    /// Trail half-life in seconds — every `trail_half_life_s` seconds
    /// the layer fades to half intensity. 0 wipes the layer transparent
    /// every frame (no trail). Swift default
    /// (`defaultShootingStarsTrailHalfLifeSeconds`) is 0.18.
    #[arg(long, default_value_t = 0.18)]
    pub shooting_stars_trail_half_life_s: f32,

    // ---- Phase 3: satellites ----
    /// Enable the satellites layer. Swift default
    /// (`defaultSatellitesEnabled`) is `true`.
    #[arg(long, action = clap::ArgAction::Set, default_value_t = true)]
    pub satellites_enabled: bool,

    /// Mean seconds between satellite spawns (exponential distribution).
    /// Floored at 0.05s internally. Swift default
    /// (`defaultSatellitesAvgSpawnSeconds`) is 0.75.
    #[arg(long, default_value_t = 0.75)]
    pub satellites_avg_spawn_seconds: f64,

    /// Satellite horizontal speed in pixels/second. Swift default
    /// (`defaultSatellitesSpeed`) is 30.
    #[arg(long, default_value_t = 30.0)]
    pub satellites_speed: f32,

    /// Satellite head sprite diameter in pixels. Floored at 1.0px
    /// internally. Swift default (`defaultSatellitesSize`) is 2.
    #[arg(long, default_value_t = 2.0)]
    pub satellites_size: f32,

    /// Satellite brightness in [0, 1.2]; the upper bound matches Swift's
    /// `satellitesBrightnessMax = 1.2` (lets satellites visually pop).
    /// Internally clamped to [0, 1]. Swift default
    /// (`defaultSatellitesBrightness`) is 0.5.
    #[arg(long, default_value_t = 0.5)]
    pub satellites_brightness: f32,

    /// Whether the satellites layer leaves a fading trail. When false,
    /// each frame wipes the layer transparent (no trail). Swift default
    /// (`defaultSatellitesTrailing`) is `true`.
    #[arg(long, action = clap::ArgAction::Set, default_value_t = true)]
    pub satellites_trailing: bool,

    /// Satellite trail half-life in seconds. 0 (with `trailing: true`)
    /// or `trailing: false` both wipe the layer every frame. Swift
    /// default (`defaultSatellitesTrailHalfLifeSeconds`) is 0.10.
    #[arg(long, default_value_t = 0.10)]
    pub satellites_trail_half_life_s: f32,

    // ---- Phase 4: moon ----
    /// Enable the moon layer. Swift default (`defaultMoonEnabled`) is true.
    #[arg(long, action = clap::ArgAction::Set, default_value_t = true)]
    pub moon_enabled: bool,

    /// Moon diameter as a fraction of the viewport width. Swift default
    /// (`defaultMoonDiameterScreenWidthPercent`) is `80/3000 ≈ 0.02667`,
    /// allowed range `0.001..=0.25`.
    #[arg(long, default_value_t = 80.0 / 3000.0)]
    pub moon_diameter_percent: f64,

    /// Brightness multiplier for the lit hemisphere. Swift default
    /// (`defaultMoonBrightBrightness`) is 1.0; slider range `0.2..=1.2`.
    #[arg(long, default_value_t = 1.0)]
    pub moon_bright_brightness: f32,

    /// Brightness multiplier for the unlit hemisphere (earthshine).
    /// Swift default (`defaultMoonDarkBrightness`) is 0.15; range
    /// `0.0..=0.9`.
    #[arg(long, default_value_t = 0.15)]
    pub moon_dark_brightness: f32,

    /// Full left→right traversal duration in seconds. Swift default
    /// (`defaultMoonTraversalMinutes = 60`) → 3600s; range `60..=43200s`
    /// (1 minute to 12 hours).
    #[arg(long, default_value_t = 3600.0)]
    pub moon_traversal_seconds: f64,

    /// Terminator rendering mode. `0` = hard step, `1` = smooth gradient,
    /// `2` = banded. Default is `1` (smooth) — the hard step produces a
    /// strong Mach-band perceptual illusion when the moon is large in the
    /// frame (sharp brightness contrast → eye perceives a dark stripe at
    /// the terminator that isn't in the pixels). Swift default
    /// (`defaultMoonTerminatorMode`) is also `1` for parity.
    #[arg(long, default_value_t = 1)]
    pub moon_terminator_mode: u32,

    /// Terminator half-width (fraction of disc, modes 1+2). Swift default
    /// (`defaultMoonTerminatorWidth`) is 0.06; range `0.01..=0.30`.
    #[arg(long, default_value_t = 0.06)]
    pub moon_terminator_width: f32,

    /// Discrete brightness band count (mode 2 only). Swift default
    /// (`defaultMoonTerminatorBands`) is 4.
    #[arg(long, default_value_t = 4)]
    pub moon_terminator_bands: u32,

    /// When true, replace the live phase calculation with a slider-driven
    /// triangular wave (see `moon_phase_override_value`). Swift default
    /// (`defaultMoonPhaseOverrideEnabled`) is false.
    #[arg(long, action = clap::ArgAction::Set, default_value_t = false)]
    pub moon_phase_override_enabled: bool,

    /// Override phase value in `[0, 1]`. `p ≤ 0.5` waxes up to full at
    /// 0.5; `p > 0.5` wanes back to new at 1.0. Swift default
    /// (`defaultMoonPhaseOverrideValue`) is 0.0.
    #[arg(long, default_value_t = 0.0)]
    pub moon_phase_override_value: f64,

    /// Debug visualisation: render the moon as its raw albedo texture
    /// only (no lighting, no terminator). Swift default
    /// (`defaultDebugMoonColors`) is false.
    #[arg(long, action = clap::ArgAction::Set, default_value_t = false)]
    pub debug_moon_colors: bool,
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
