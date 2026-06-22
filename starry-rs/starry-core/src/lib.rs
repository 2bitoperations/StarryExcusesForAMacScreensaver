//! starry-core — window-agnostic simulation + GPU rendering for starry-rs.
//!
//! This crate owns everything that doesn't need a window:
//! - the deterministic simulation (`Engine` + per-layer renderers in
//!   `skyline`, `satellites`, `shooting_stars`)
//! - the wgpu rendering pipelines (`gpu::GpuPipelines`) that consume the
//!   engine's `FrameOutput` and draw into any user-supplied texture view
//! - the headless single-frame PNG dump (`headless::dump_png`)
//! - the CLI `Config` (clap-derive) so both the windowed shell and any
//!   future test harness share one config surface
//!
//! The windowed shell (winit + Surface) lives in the sibling `starry-app`
//! crate, which depends on this one and adapts `GpuPipelines` onto a real
//! swapchain.

pub mod buildings;
pub mod composite;
pub mod config;
pub mod decay;
pub mod engine;
pub mod gpu;
pub mod headless;
pub mod moon;
pub mod moon_renderer;
pub mod moon_texture;
pub mod planet;
pub mod planet_renderer;
pub mod planet_texture;
pub mod satellites;
pub mod shooting_stars;
pub mod skyline;
pub mod skyline_renderer;
pub mod sprite;
pub mod toml_config;
pub mod types;
