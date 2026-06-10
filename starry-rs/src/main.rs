//! starry-rs — cross-platform Rust + wgpu port of the macOS Starry Night
//! screensaver. Entry point: dispatches to either the windowed shell or
//! the headless single-frame PNG dump mode based on CLI args.

mod app;
mod gpu;
mod headless;
mod scene;
mod sprite;

use std::path::PathBuf;

use winit::event_loop::{ControlFlow, EventLoop};

use crate::{
    app::App,
    scene::{DEFAULT_HEIGHT, DEFAULT_WIDTH},
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    log::info!("starry-rs phase 1 starting — homage to the homage to the homage");

    if let Some(path) = parse_dump_png_arg()? {
        return headless::dump_png(&path, DEFAULT_WIDTH, DEFAULT_HEIGHT);
    }

    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(ControlFlow::Poll);

    let mut app = App::default();
    event_loop.run_app(&mut app)?;
    Ok(())
}

fn parse_dump_png_arg() -> Result<Option<PathBuf>, Box<dyn std::error::Error>> {
    let mut iter = std::env::args().skip(1);
    while let Some(arg) = iter.next() {
        if arg == "--dump-png" {
            let path = iter
                .next()
                .ok_or("--dump-png requires a path argument")?;
            return Ok(Some(PathBuf::from(path)));
        } else {
            return Err(format!("unknown argument: {arg}").into());
        }
    }
    Ok(None)
}
