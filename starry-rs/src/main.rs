//! starry-rs — cross-platform Rust + wgpu port of the macOS Starry Night
//! screensaver. Entry point: parses CLI args via clap, then dispatches to
//! either the headless single-frame PNG dump or the windowed shell.

mod app;
mod buildings;
mod composite;
mod config;
mod decay;
mod engine;
mod gpu;
mod headless;
mod satellites;
mod shooting_stars;
mod skyline;
mod skyline_renderer;
mod sprite;
mod types;

use clap::Parser;
use winit::event_loop::{ControlFlow, EventLoop};

use crate::{app::App, config::Config};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let config = Config::parse();
    log::info!("starry-rs phase 2 starting — homage to the homage to the homage");

    if config.dump_png.is_some() {
        return headless::dump_png(&config);
    }

    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(ControlFlow::Poll);

    let mut app = App::new(config);
    event_loop.run_app(&mut app)?;
    Ok(())
}
