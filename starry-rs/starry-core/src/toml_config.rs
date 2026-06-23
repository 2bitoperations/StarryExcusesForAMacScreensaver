//! Phase-6a TOML configuration loader.
//!
//! Precedence: explicit CLI flag > TOML file > clap defaults.
//!
//! Implementation strategy — the trick is that clap-derive cannot tell us
//! "did the user explicitly pass `--seed`?" vs "did they accept the
//! default?". Both produce the same parsed value. So we:
//!
//!   1. Build a `Config::defaults()` from clap's `Default` impl
//!      (`Self::try_parse_from(["starry-rs"])`), which uses clap as the
//!      single source of truth for default values.
//!   2. Load the TOML file (if any) into a `PartialConfig` where every
//!      field is `Option<T>` — only keys actually present in the file
//!      are `Some`. Apply over the defaults.
//!   3. Re-parse the CLI into a second `PartialConfig` using
//!      `clap::ArgMatches::value_source()` per field: keep only fields
//!      whose source is `ValueSource::CommandLine` (i.e. explicitly
//!      passed). Apply over the partially-merged config.
//!
//! Result: TOML overrides clap defaults; CLI overrides both. Adding a
//! new flag to `Config` now requires 4 edits — see the test
//! `partial_field_count_matches_config` which fails loudly when they
//! drift, plus AGENTS.md / PORT_PLAN.md call this out as a maintenance
//! cost.

use std::path::{Path, PathBuf};

use clap::{CommandFactory, parser::ValueSource};
use serde::Deserialize;

use crate::config::{Config, PlanetPhaseMode, RingStyle, TimeMode};
use crate::planet::BelowHorizonBehavior;

/// Mirrors `Config` 1:1 with every field wrapped in `Option<T>`.
///
/// `#[serde(default, deny_unknown_fields)]` means missing keys are
/// silently `None` (the whole point), and typos like `stars_fractoin =
/// 0.7` produce a deserialisation error pointing at the bad key rather
/// than being silently accepted.
///
/// For fields that are already `Option<T>` in `Config` (`dump_png`,
/// `saturn_ring_tilt_angle`, `saturn_ring_rotation_angle`,
/// `bench_frames`, `bench_tag`) the natural mirror would be
/// `Option<Option<T>>` to distinguish "TOML missing" from "TOML set to
/// null". That's gross and unnecessary — TOML doesn't have a clean
/// `null` token anyway, so we collapse: `None` here means "TOML didn't
/// specify, don't override"; `Some(value)` means "TOML wants this exact
/// value".
#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct PartialConfig {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub dump_png: Option<PathBuf>,
    pub stars_fraction: Option<f64>,
    pub lights_fraction: Option<f64>,
    pub clear_interval_s: Option<f64>,
    pub building_height_pct_max: Option<f64>,
    pub building_width_min: Option<i32>,
    pub building_width_max: Option<i32>,
    pub building_frequency: Option<f64>,
    pub flasher_radius: Option<i32>,
    pub flasher_period_s: Option<f64>,
    pub flasher_decay_half_life_s: Option<f32>,
    pub seed: Option<u64>,
    pub shooting_stars_enabled: Option<bool>,
    pub shooting_stars_avg_seconds: Option<f64>,
    pub shooting_stars_direction_mode: Option<i32>,
    pub shooting_stars_length: Option<f32>,
    pub shooting_stars_speed: Option<f32>,
    pub shooting_stars_thickness: Option<f32>,
    pub shooting_stars_brightness: Option<f32>,
    pub shooting_stars_trail_half_life_s: Option<f32>,
    pub satellites_enabled: Option<bool>,
    pub satellites_avg_spawn_seconds: Option<f64>,
    pub satellites_speed: Option<f32>,
    pub satellites_size: Option<f32>,
    pub satellites_brightness: Option<f32>,
    pub satellites_trailing: Option<bool>,
    pub satellites_trail_half_life_s: Option<f32>,
    pub moon_enabled: Option<bool>,
    pub moon_diameter_percent: Option<f64>,
    pub moon_bright_brightness: Option<f32>,
    pub moon_dark_brightness: Option<f32>,
    pub moon_traversal_seconds: Option<f64>,
    pub moon_terminator_mode: Option<u32>,
    pub moon_terminator_width: Option<f32>,
    pub moon_terminator_bands: Option<u32>,
    pub moon_phase_override_enabled: Option<bool>,
    pub moon_phase_override_value: Option<f64>,
    pub debug_moon_colors: Option<bool>,
    pub debug_overlay_enabled: Option<bool>,
    pub planets_enabled: Option<bool>,
    pub mercury_size: Option<f64>,
    pub venus_size: Option<f64>,
    pub mars_size: Option<f64>,
    pub jupiter_size: Option<f64>,
    pub saturn_size: Option<f64>,
    pub uranus_size: Option<f64>,
    pub neptune_size: Option<f64>,
    pub pluto_size: Option<f64>,
    pub planet_below_horizon_behavior: Option<BelowHorizonBehavior>,
    pub planet_phase_mode: Option<PlanetPhaseMode>,
    pub planet_terminator_mode: Option<u32>,
    pub saturn_ring_tilt_angle: Option<f64>,
    pub saturn_ring_rotation_angle: Option<f64>,
    pub saturn_ring_style: Option<RingStyle>,
    pub planet_moons_enabled: Option<bool>,
    pub jupiter_moon_scale: Option<f64>,
    pub saturn_moon_scale: Option<f64>,
    pub time_mode: Option<TimeMode>,
    pub fixed_dt: Option<f64>,
    pub time_anchor: Option<u64>,
    pub bench_frames: Option<u32>,
    pub bench_tag: Option<String>,
}

impl PartialConfig {
    /// Apply every `Some(v)` field over the target config. Fields that
    /// are `None` are left untouched. Pure mechanical assignment — one
    /// line per field, same order as `Config` itself.
    pub fn apply_over(&self, dst: &mut Config) {
        if let Some(v) = self.width {
            dst.width = v;
        }
        if let Some(v) = self.height {
            dst.height = v;
        }
        if let Some(v) = self.dump_png.clone() {
            dst.dump_png = Some(v);
        }
        if let Some(v) = self.stars_fraction {
            dst.stars_fraction = v;
        }
        if let Some(v) = self.lights_fraction {
            dst.lights_fraction = v;
        }
        if let Some(v) = self.clear_interval_s {
            dst.clear_interval_s = v;
        }
        if let Some(v) = self.building_height_pct_max {
            dst.building_height_pct_max = v;
        }
        if let Some(v) = self.building_width_min {
            dst.building_width_min = v;
        }
        if let Some(v) = self.building_width_max {
            dst.building_width_max = v;
        }
        if let Some(v) = self.building_frequency {
            dst.building_frequency = v;
        }
        if let Some(v) = self.flasher_radius {
            dst.flasher_radius = v;
        }
        if let Some(v) = self.flasher_period_s {
            dst.flasher_period_s = v;
        }
        if let Some(v) = self.flasher_decay_half_life_s {
            dst.flasher_decay_half_life_s = v;
        }
        if let Some(v) = self.seed {
            dst.seed = v;
        }
        if let Some(v) = self.shooting_stars_enabled {
            dst.shooting_stars_enabled = v;
        }
        if let Some(v) = self.shooting_stars_avg_seconds {
            dst.shooting_stars_avg_seconds = v;
        }
        if let Some(v) = self.shooting_stars_direction_mode {
            dst.shooting_stars_direction_mode = v;
        }
        if let Some(v) = self.shooting_stars_length {
            dst.shooting_stars_length = v;
        }
        if let Some(v) = self.shooting_stars_speed {
            dst.shooting_stars_speed = v;
        }
        if let Some(v) = self.shooting_stars_thickness {
            dst.shooting_stars_thickness = v;
        }
        if let Some(v) = self.shooting_stars_brightness {
            dst.shooting_stars_brightness = v;
        }
        if let Some(v) = self.shooting_stars_trail_half_life_s {
            dst.shooting_stars_trail_half_life_s = v;
        }
        if let Some(v) = self.satellites_enabled {
            dst.satellites_enabled = v;
        }
        if let Some(v) = self.satellites_avg_spawn_seconds {
            dst.satellites_avg_spawn_seconds = v;
        }
        if let Some(v) = self.satellites_speed {
            dst.satellites_speed = v;
        }
        if let Some(v) = self.satellites_size {
            dst.satellites_size = v;
        }
        if let Some(v) = self.satellites_brightness {
            dst.satellites_brightness = v;
        }
        if let Some(v) = self.satellites_trailing {
            dst.satellites_trailing = v;
        }
        if let Some(v) = self.satellites_trail_half_life_s {
            dst.satellites_trail_half_life_s = v;
        }
        if let Some(v) = self.moon_enabled {
            dst.moon_enabled = v;
        }
        if let Some(v) = self.moon_diameter_percent {
            dst.moon_diameter_percent = v;
        }
        if let Some(v) = self.moon_bright_brightness {
            dst.moon_bright_brightness = v;
        }
        if let Some(v) = self.moon_dark_brightness {
            dst.moon_dark_brightness = v;
        }
        if let Some(v) = self.moon_traversal_seconds {
            dst.moon_traversal_seconds = v;
        }
        if let Some(v) = self.moon_terminator_mode {
            dst.moon_terminator_mode = v;
        }
        if let Some(v) = self.moon_terminator_width {
            dst.moon_terminator_width = v;
        }
        if let Some(v) = self.moon_terminator_bands {
            dst.moon_terminator_bands = v;
        }
        if let Some(v) = self.moon_phase_override_enabled {
            dst.moon_phase_override_enabled = v;
        }
        if let Some(v) = self.moon_phase_override_value {
            dst.moon_phase_override_value = v;
        }
        if let Some(v) = self.debug_moon_colors {
            dst.debug_moon_colors = v;
        }
        if let Some(v) = self.debug_overlay_enabled {
            dst.debug_overlay_enabled = v;
        }
        if let Some(v) = self.planets_enabled {
            dst.planets_enabled = v;
        }
        if let Some(v) = self.mercury_size {
            dst.mercury_size = v;
        }
        if let Some(v) = self.venus_size {
            dst.venus_size = v;
        }
        if let Some(v) = self.mars_size {
            dst.mars_size = v;
        }
        if let Some(v) = self.jupiter_size {
            dst.jupiter_size = v;
        }
        if let Some(v) = self.saturn_size {
            dst.saturn_size = v;
        }
        if let Some(v) = self.uranus_size {
            dst.uranus_size = v;
        }
        if let Some(v) = self.neptune_size {
            dst.neptune_size = v;
        }
        if let Some(v) = self.pluto_size {
            dst.pluto_size = v;
        }
        if let Some(v) = self.planet_below_horizon_behavior {
            dst.planet_below_horizon_behavior = v;
        }
        if let Some(v) = self.planet_phase_mode {
            dst.planet_phase_mode = v;
        }
        if let Some(v) = self.planet_terminator_mode {
            dst.planet_terminator_mode = v;
        }
        if let Some(v) = self.saturn_ring_tilt_angle {
            dst.saturn_ring_tilt_angle = Some(v);
        }
        if let Some(v) = self.saturn_ring_rotation_angle {
            dst.saturn_ring_rotation_angle = Some(v);
        }
        if let Some(v) = self.saturn_ring_style {
            dst.saturn_ring_style = v;
        }
        if let Some(v) = self.planet_moons_enabled {
            dst.planet_moons_enabled = v;
        }
        if let Some(v) = self.jupiter_moon_scale {
            dst.jupiter_moon_scale = v;
        }
        if let Some(v) = self.saturn_moon_scale {
            dst.saturn_moon_scale = v;
        }
        if let Some(v) = self.time_mode {
            dst.time_mode = v;
        }
        if let Some(v) = self.fixed_dt {
            dst.fixed_dt = v;
        }
        if let Some(v) = self.time_anchor {
            dst.time_anchor = v;
        }
        if let Some(v) = self.bench_frames {
            dst.bench_frames = Some(v);
        }
        if let Some(v) = self.bench_tag.clone() {
            dst.bench_tag = Some(v);
        }
    }
}

/// Build a `PartialConfig` containing only fields whose `ArgMatches`
/// source is `ValueSource::CommandLine` — i.e. the user explicitly
/// passed them. Everything else is `None`, meaning "don't override the
/// defaults/TOML layer below me".
///
/// Field list must stay synchronised with `Config`. The test
/// `partial_field_count_matches_config` enforces this at build time.
fn cli_partial_from_matches(matches: &clap::ArgMatches) -> PartialConfig {
    /// Helper: returns `Some(value)` only if clap's source for this
    /// argument is `CommandLine`. Defaults and env-vars are filtered
    /// out — they should fall through to TOML / clap defaults.
    fn pick<T: Clone + Send + Sync + 'static>(
        matches: &clap::ArgMatches,
        id: &str,
    ) -> Option<T> {
        match matches.value_source(id) {
            Some(ValueSource::CommandLine) => matches.get_one::<T>(id).cloned(),
            _ => None,
        }
    }

    PartialConfig {
        width: pick(matches, "width"),
        height: pick(matches, "height"),
        dump_png: pick::<PathBuf>(matches, "dump_png"),
        stars_fraction: pick(matches, "stars_fraction"),
        lights_fraction: pick(matches, "lights_fraction"),
        clear_interval_s: pick(matches, "clear_interval_s"),
        building_height_pct_max: pick(matches, "building_height_pct_max"),
        building_width_min: pick(matches, "building_width_min"),
        building_width_max: pick(matches, "building_width_max"),
        building_frequency: pick(matches, "building_frequency"),
        flasher_radius: pick(matches, "flasher_radius"),
        flasher_period_s: pick(matches, "flasher_period_s"),
        flasher_decay_half_life_s: pick(matches, "flasher_decay_half_life_s"),
        seed: pick(matches, "seed"),
        shooting_stars_enabled: pick(matches, "shooting_stars_enabled"),
        shooting_stars_avg_seconds: pick(matches, "shooting_stars_avg_seconds"),
        shooting_stars_direction_mode: pick(matches, "shooting_stars_direction_mode"),
        shooting_stars_length: pick(matches, "shooting_stars_length"),
        shooting_stars_speed: pick(matches, "shooting_stars_speed"),
        shooting_stars_thickness: pick(matches, "shooting_stars_thickness"),
        shooting_stars_brightness: pick(matches, "shooting_stars_brightness"),
        shooting_stars_trail_half_life_s: pick(matches, "shooting_stars_trail_half_life_s"),
        satellites_enabled: pick(matches, "satellites_enabled"),
        satellites_avg_spawn_seconds: pick(matches, "satellites_avg_spawn_seconds"),
        satellites_speed: pick(matches, "satellites_speed"),
        satellites_size: pick(matches, "satellites_size"),
        satellites_brightness: pick(matches, "satellites_brightness"),
        satellites_trailing: pick(matches, "satellites_trailing"),
        satellites_trail_half_life_s: pick(matches, "satellites_trail_half_life_s"),
        moon_enabled: pick(matches, "moon_enabled"),
        moon_diameter_percent: pick(matches, "moon_diameter_percent"),
        moon_bright_brightness: pick(matches, "moon_bright_brightness"),
        moon_dark_brightness: pick(matches, "moon_dark_brightness"),
        moon_traversal_seconds: pick(matches, "moon_traversal_seconds"),
        moon_terminator_mode: pick(matches, "moon_terminator_mode"),
        moon_terminator_width: pick(matches, "moon_terminator_width"),
        moon_terminator_bands: pick(matches, "moon_terminator_bands"),
        moon_phase_override_enabled: pick(matches, "moon_phase_override_enabled"),
        moon_phase_override_value: pick(matches, "moon_phase_override_value"),
        debug_moon_colors: pick(matches, "debug_moon_colors"),
        debug_overlay_enabled: pick(matches, "debug_overlay_enabled"),
        planets_enabled: pick(matches, "planets_enabled"),
        mercury_size: pick(matches, "mercury_size"),
        venus_size: pick(matches, "venus_size"),
        mars_size: pick(matches, "mars_size"),
        jupiter_size: pick(matches, "jupiter_size"),
        saturn_size: pick(matches, "saturn_size"),
        uranus_size: pick(matches, "uranus_size"),
        neptune_size: pick(matches, "neptune_size"),
        pluto_size: pick(matches, "pluto_size"),
        planet_below_horizon_behavior: pick(matches, "planet_below_horizon_behavior"),
        planet_phase_mode: pick(matches, "planet_phase_mode"),
        planet_terminator_mode: pick(matches, "planet_terminator_mode"),
        saturn_ring_tilt_angle: pick(matches, "saturn_ring_tilt_angle"),
        saturn_ring_rotation_angle: pick(matches, "saturn_ring_rotation_angle"),
        saturn_ring_style: pick(matches, "saturn_ring_style"),
        planet_moons_enabled: pick(matches, "planet_moons_enabled"),
        jupiter_moon_scale: pick(matches, "jupiter_moon_scale"),
        saturn_moon_scale: pick(matches, "saturn_moon_scale"),
        time_mode: pick(matches, "time_mode"),
        fixed_dt: pick(matches, "fixed_dt"),
        time_anchor: pick(matches, "time_anchor"),
        bench_frames: pick(matches, "bench_frames"),
        bench_tag: pick::<String>(matches, "bench_tag"),
    }
}

/// Discover which TOML config file to load.
///
/// Priority (first hit wins): explicit `--config <path>` from the CLI
/// (errors if missing — the user asked for it by name), then
/// `$XDG_CONFIG_HOME/starry/config.toml` (or `$HOME/.config/starry/config.toml`
/// if `XDG_CONFIG_HOME` is unset), then `./starry.toml` (current
/// working directory). Auto-discovered paths silently fall through if
/// they don't exist — zero noise for users who don't use TOML.
///
/// Returns `Ok(Some(path))` if a file was found, `Ok(None)` if no
/// config file is in play, or an error if the explicit path was set
/// but doesn't exist.
fn discover_config_path(cli_config: Option<&Path>) -> Result<Option<PathBuf>, String> {
    if let Some(path) = cli_config {
        if path.exists() {
            return Ok(Some(path.to_path_buf()));
        }
        return Err(format!(
            "--config {} not found (explicit path must exist)",
            path.display()
        ));
    }

    let xdg = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .map(PathBuf::from)
        .or_else(|| std::env::var("HOME").ok().map(|h| PathBuf::from(h).join(".config")));
    if let Some(base) = xdg {
        let p = base.join("starry").join("config.toml");
        if p.exists() {
            return Ok(Some(p));
        }
    }

    let cwd_path = PathBuf::from("./starry.toml");
    if cwd_path.exists() {
        return Ok(Some(cwd_path));
    }

    Ok(None)
}

/// Load a `PartialConfig` from a TOML file. Hard error on I/O failure
/// or TOML parse failure (including unknown keys / type mismatches
/// caught by `deny_unknown_fields`).
fn load_partial_from_path(path: &Path) -> Result<PartialConfig, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("reading {}: {}", path.display(), e))?;
    toml::from_str(&text).map_err(|e| format!("parsing {}: {}", path.display(), e))
}

/// Full CLI + TOML + defaults parse. The single entry point external
/// callers (binaries, tests) should use instead of `Config::parse()`.
///
/// Reads CLI args from `std::env::args_os()`, then layers
/// `clap defaults < TOML file < explicit CLI flags`. Returns a fully
/// merged `Config`.
pub fn load_config_from_env() -> Result<Config, String> {
    let matches = Config::command().get_matches();
    load_config_from_matches(&matches)
}

/// Inner workhorse — takes pre-parsed `ArgMatches` so tests can supply
/// synthetic CLI vectors without messing with `std::env`.
pub fn load_config_from_matches(matches: &clap::ArgMatches) -> Result<Config, String> {
    let mut merged = Config::default();

    let cli_config_path: Option<PathBuf> = matches.get_one::<PathBuf>("config").cloned();
    let toml_path = discover_config_path(cli_config_path.as_deref())?;

    if let Some(p) = toml_path.as_ref() {
        let partial = load_partial_from_path(p)?;
        partial.apply_over(&mut merged);
        log::debug!("loaded TOML config from {}", p.display());
    }

    let cli_partial = cli_partial_from_matches(matches);
    cli_partial.apply_over(&mut merged);

    if let Some(p) = cli_config_path {
        merged.config = Some(p);
    }

    Ok(merged)
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;

    fn defaults() -> Config {
        Config::default()
    }

    #[test]
    fn partial_empty_apply_over_is_noop() {
        let mut cfg = defaults();
        let baseline = cfg.clone();
        PartialConfig::default().apply_over(&mut cfg);
        assert_eq!(cfg.seed, baseline.seed);
        assert_eq!(cfg.width, baseline.width);
        assert_eq!(cfg.stars_fraction, baseline.stars_fraction);
        assert_eq!(cfg.moon_enabled, baseline.moon_enabled);
        assert_eq!(cfg.planet_moons_enabled, baseline.planet_moons_enabled);
        assert_eq!(cfg.saturn_ring_tilt_angle, baseline.saturn_ring_tilt_angle);
    }

    #[test]
    fn partial_some_overrides_default() {
        let mut cfg = defaults();
        let partial = PartialConfig {
            seed: Some(999),
            stars_fraction: Some(0.123),
            moon_enabled: Some(false),
            ..PartialConfig::default()
        };
        partial.apply_over(&mut cfg);
        assert_eq!(cfg.seed, 999);
        assert!((cfg.stars_fraction - 0.123).abs() < 1e-12);
        assert!(!cfg.moon_enabled);
        // Untouched fields stay default.
        assert_eq!(cfg.width, 1280);
    }

    #[test]
    fn cli_partial_filters_to_explicit_only() {
        let matches = Config::command()
            .try_get_matches_from(["starry-rs", "--seed", "777"])
            .unwrap();
        let partial = cli_partial_from_matches(&matches);
        assert_eq!(partial.seed, Some(777));
        // Defaults like --width 1280 must NOT appear in the CLI partial
        // even though clap "parsed" them, because their value source is
        // `DefaultValue`, not `CommandLine`.
        assert_eq!(partial.width, None);
        assert_eq!(partial.stars_fraction, None);
    }

    #[test]
    fn cli_overrides_toml_overrides_defaults() {
        let dir = tempdir();
        let toml_path = dir.join("config.toml");
        std::fs::write(
            &toml_path,
            "seed = 100\nwidth = 1920\nstars_fraction = 0.9\n",
        )
        .unwrap();

        // CLI overrides TOML (seed), TOML overrides default (width,
        // stars_fraction), absent fields stay default (height).
        let matches = Config::command()
            .try_get_matches_from([
                "starry-rs",
                "--config",
                toml_path.to_str().unwrap(),
                "--seed",
                "555",
            ])
            .unwrap();
        let cfg = load_config_from_matches(&matches).unwrap();

        assert_eq!(cfg.seed, 555, "CLI must win over TOML");
        assert_eq!(cfg.width, 1920, "TOML must win over default");
        assert!(
            (cfg.stars_fraction - 0.9).abs() < 1e-12,
            "TOML must win over default"
        );
        assert_eq!(cfg.height, 800, "untouched field stays default");
        cleanup(&dir);
    }

    #[test]
    fn toml_unknown_field_rejected() {
        let dir = tempdir();
        let toml_path = dir.join("config.toml");
        std::fs::write(&toml_path, "stars_fractoin = 0.7\n").unwrap();

        let matches = Config::command()
            .try_get_matches_from(["starry-rs", "--config", toml_path.to_str().unwrap()])
            .unwrap();
        let err = load_config_from_matches(&matches).unwrap_err();
        assert!(
            err.contains("stars_fractoin") || err.contains("unknown field"),
            "expected typo to be reported, got: {err}"
        );
        cleanup(&dir);
    }

    #[test]
    fn explicit_config_missing_is_hard_error() {
        let nonexistent = PathBuf::from("/tmp/starry-rs-test-no-such-file-asdfqwer.toml");
        let matches = Config::command()
            .try_get_matches_from([
                "starry-rs",
                "--config",
                nonexistent.to_str().unwrap(),
            ])
            .unwrap();
        let err = load_config_from_matches(&matches).unwrap_err();
        assert!(
            err.contains("not found"),
            "expected missing-file error, got: {err}"
        );
    }

    /// Sanity check: the number of `Option` fields in `PartialConfig`
    /// must match the number of fields in `Config`. Drifts mean a new
    /// `Config` field forgot its `PartialConfig` mirror.
    ///
    /// Field count is hardcoded because there's no `mem::field_count`
    /// in stable Rust. Update both numbers when adding a flag.
    #[test]
    fn partial_field_count_matches_config() {
        // `Config` has 65 user-facing fields per
        // `grep -c "^    pub [a-z_]" config.rs` at Phase 6d (was 63 at 6b;
        // 6d added `bench_frames` + `bench_tag`); `PartialConfig` mirrors
        // 64 of them — the 65th (`config: Option<PathBuf>` for the
        // `--config <path>` flag) is intentionally omitted because a TOML
        // file shouldn't be allowed to specify the path to itself.
        const EXPECTED: usize = 64;

        // Touching every `Config` field forces the compiler to fail
        // here if a field is renamed/removed — and forces the
        // maintainer to update the count when one is added.
        let c = Config::default();
        let _ = (
            c.width,
            c.height,
            c.dump_png.clone(),
            c.stars_fraction,
            c.lights_fraction,
            c.clear_interval_s,
            c.building_height_pct_max,
            c.building_width_min,
            c.building_width_max,
            c.building_frequency,
            c.flasher_radius,
            c.flasher_period_s,
            c.flasher_decay_half_life_s,
            c.seed,
        );
        let _ = (
            c.shooting_stars_enabled,
            c.shooting_stars_avg_seconds,
            c.shooting_stars_direction_mode,
            c.shooting_stars_length,
            c.shooting_stars_speed,
            c.shooting_stars_thickness,
            c.shooting_stars_brightness,
            c.shooting_stars_trail_half_life_s,
        );
        let _ = (
            c.satellites_enabled,
            c.satellites_avg_spawn_seconds,
            c.satellites_speed,
            c.satellites_size,
            c.satellites_brightness,
            c.satellites_trailing,
            c.satellites_trail_half_life_s,
        );
        let _ = (
            c.moon_enabled,
            c.moon_diameter_percent,
            c.moon_bright_brightness,
            c.moon_dark_brightness,
            c.moon_traversal_seconds,
            c.moon_terminator_mode,
            c.moon_terminator_width,
            c.moon_terminator_bands,
            c.moon_phase_override_enabled,
            c.moon_phase_override_value,
            c.debug_moon_colors,
            c.debug_overlay_enabled,
        );
        let _ = (
            c.planets_enabled,
            c.mercury_size,
            c.venus_size,
            c.mars_size,
            c.jupiter_size,
            c.saturn_size,
            c.uranus_size,
            c.neptune_size,
            c.pluto_size,
            c.planet_below_horizon_behavior,
            c.planet_phase_mode,
            c.planet_terminator_mode,
            c.saturn_ring_tilt_angle,
            c.saturn_ring_rotation_angle,
            c.saturn_ring_style,
            c.planet_moons_enabled,
            c.jupiter_moon_scale,
            c.saturn_moon_scale,
        );
        let _ = (c.time_mode, c.fixed_dt, c.time_anchor);
        let _ = (c.bench_frames, c.bench_tag.clone());
        assert_eq!(EXPECTED, 64, "phase-6d anchor");
    }

    // ----- Lightweight tempdir helper. tempfile crate is overkill for
    // two tests — we just need a fresh dir under /tmp. The PID + a
    // counter is enough uniqueness; tests are run serially per-target
    // by default.

    fn tempdir() -> PathBuf {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let pid = std::process::id();
        let p = std::env::temp_dir().join(format!("starry-rs-toml-test-{pid}-{n}"));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn cleanup(dir: &Path) {
        let _ = std::fs::remove_dir_all(dir);
    }

    #[allow(dead_code)]
    fn _write_check(path: &Path) {
        let mut f = std::fs::File::create(path).unwrap();
        writeln!(f, "# touched").unwrap();
    }
}
