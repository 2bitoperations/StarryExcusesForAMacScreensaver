//! starry-app — windowed shell + CLI entry point for starry-rs. Parses
//! CLI args via clap, then dispatches to either the headless single-frame
//! PNG dump (in `starry_core::headless`) or the windowed shell (this
//! crate's `app` module driving `starry_core::gpu::GpuPipelines`).

mod app;
mod gpu;

use starry_core::toml_config::load_config_from_env;
use winit::event_loop::{ControlFlow, EventLoop};

use crate::app::App;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    // Phase 6a: layered config — clap defaults < TOML file < explicit CLI.
    // See `starry_core::toml_config` for precedence + path-discovery rules.
    let config = load_config_from_env()?;
    log::info!("starry-rs phase 6a starting — homage to the homage to the homage");

    if config.dump_png.is_some() {
        return starry_core::headless::dump_png(&config);
    }

    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(ControlFlow::Poll);

    let mut app = App::new(config);
    event_loop.run_app(&mut app)?;
    Ok(())
}
