//! winit `ApplicationHandler` for the windowed shell. Owns the window, the
//! GPU state, and the simulation `Engine`. Each redraw advances the engine
//! using the configured `TimeMode`: `realtime` derives dt from `Instant`
//! and `wall_now` from `SystemTime::now()`; `deterministic` advances
//! `wall_now` by `fixed_dt` per frame from `time_anchor` and skips the
//! dt clamp; `frozen` pins both to `time_anchor` with dt=0.
//!
//! Resize policy: rebuilds the `Engine` from scratch (preserving `seed`)
//! whenever the surface dimensions change. The skyline geometry is
//! resolution-dependent (building positions and the per-column sky-floor
//! are sized to the canvas), so the cleanest way to stay correct is to
//! regenerate it. Skyline generation is cheap — see `Skyline::new` — so
//! even drag-resize stays smooth, but we still gate on actual dimension
//! changes to avoid pointless work on no-op `Resized` events.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use starry_core::{
    config::{Config, TimeMode},
    engine::Engine,
};
use winit::{
    application::ApplicationHandler,
    dpi::PhysicalSize,
    event::WindowEvent,
    event_loop::ActiveEventLoop,
    window::{Window, WindowId},
};

use crate::gpu::WindowedGpu;

pub struct App {
    config: Config,
    window: Option<Arc<Window>>,
    gpu: Option<WindowedGpu>,
    engine: Option<Engine>,
    /// Monotonic counter advanced once per redraw in `TimeMode::Deterministic`
    /// to compute `wall_now = anchor + frame_count × fixed_dt`. Unread by
    /// other time modes. Reset to 0 on engine rebuild (resize) so the
    /// deterministic timeline restarts from the anchor instead of
    /// teleporting the simulation forward by accumulated frames.
    frame_count: u64,
}

impl App {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            window: None,
            gpu: None,
            engine: None,
            frame_count: 0,
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }

        let window = Arc::new(
            event_loop
                .create_window(
                    Window::default_attributes()
                        .with_title("starry-rs")
                        .with_inner_size(PhysicalSize::new(self.config.width, self.config.height)),
                )
                .expect("create winit window"),
        );

        let gpu = WindowedGpu::new(window.clone(), &self.config);

        let size = window.inner_size();
        let initial_config = config_with_dims(&self.config, size.width, size.height);
        let engine = Engine::new(initial_config);
        log::info!(
            "engine initialised at {}x{} (seed={})",
            size.width,
            size.height,
            self.config.seed
        );

        self.window = Some(window);
        self.gpu = Some(gpu);
        self.engine = Some(engine);
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let (Some(gpu), Some(window), Some(engine)) = (
            self.gpu.as_mut(),
            self.window.as_ref(),
            self.engine.as_mut(),
        ) else {
            return;
        };

        match event {
            WindowEvent::CloseRequested => {
                log::info!("window close requested; exiting");
                event_loop.exit();
            }

            WindowEvent::Resized(new_size) => {
                if new_size.width == 0 || new_size.height == 0 {
                    return;
                }
                // Use the size `gpu.resize` actually applied (after any
                // max-texture-dimension clamp) so the engine matches the
                // surface dimensions exactly.
                let actual = gpu.resize(new_size);
                if engine.width() != actual.width || engine.height() != actual.height {
                    let rebuilt = config_with_dims(&self.config, actual.width, actual.height);
                    *engine = Engine::new(rebuilt);
                    self.frame_count = 0;
                    log::info!(
                        "engine rebuilt at {}x{} (seed preserved)",
                        actual.width,
                        actual.height
                    );
                }
                window.request_redraw();
            }

            WindowEvent::RedrawRequested => {
                let frame_output = match self.config.time_mode {
                    TimeMode::Realtime => engine.frame(SystemTime::now()),
                    TimeMode::Deterministic => {
                        let wall_now = deterministic_wall_now(&self.config, self.frame_count);
                        self.frame_count = self.frame_count.saturating_add(1);
                        engine.frame_with_dt(self.config.fixed_dt, wall_now)
                    }
                    TimeMode::Frozen => {
                        let anchor = UNIX_EPOCH + Duration::from_secs(self.config.time_anchor);
                        engine.frame_with_dt(0.0, anchor)
                    }
                };
                gpu.render(frame_output);
            }

            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(window) = &self.window {
            window.request_redraw();
        }
    }
}

fn config_with_dims(base: &Config, width: u32, height: u32) -> Config {
    let mut c = base.clone();
    c.width = width;
    c.height = height;
    c
}

/// Compute `wall_now` for `TimeMode::Deterministic`. Negative or non-finite
/// `fixed_dt` is clamped to zero so `Duration::from_secs_f64` never
/// panics; in practice clap rejects non-numeric values, so this is just
/// belt-and-suspenders.
fn deterministic_wall_now(cfg: &Config, frame_count: u64) -> SystemTime {
    let anchor = UNIX_EPOCH + Duration::from_secs(cfg.time_anchor);
    let elapsed = (cfg.fixed_dt * frame_count as f64).max(0.0);
    anchor + Duration::from_secs_f64(elapsed)
}
