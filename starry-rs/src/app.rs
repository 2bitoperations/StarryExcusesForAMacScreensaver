//! winit `ApplicationHandler` for the windowed shell. Owns the window, the
//! GPU state, and the simulation `Engine`. Each redraw advances the engine
//! by wall-clock dt and hands the resulting `FrameOutput` to the GPU.
//!
//! Resize policy: rebuilds the `Engine` from scratch (preserving `seed`)
//! whenever the surface dimensions change. The skyline geometry is
//! resolution-dependent (building positions and the per-column sky-floor
//! are sized to the canvas), so the cleanest way to stay correct is to
//! regenerate it. Skyline generation is cheap — see `Skyline::new` — so
//! even drag-resize stays smooth, but we still gate on actual dimension
//! changes to avoid pointless work on no-op `Resized` events.

use std::sync::Arc;

use winit::{
    application::ApplicationHandler,
    dpi::PhysicalSize,
    event::WindowEvent,
    event_loop::ActiveEventLoop,
    window::{Window, WindowId},
};

use crate::{config::Config, engine::Engine, gpu::GpuState};

pub struct App {
    config: Config,
    window: Option<Arc<Window>>,
    gpu: Option<GpuState>,
    engine: Option<Engine>,
}

impl App {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            window: None,
            gpu: None,
            engine: None,
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
                        .with_title("starry-rs — phase 2")
                        .with_inner_size(PhysicalSize::new(self.config.width, self.config.height)),
                )
                .expect("create winit window"),
        );

        let gpu = GpuState::new(window.clone(), &self.config);

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

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _id: WindowId,
        event: WindowEvent,
    ) {
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
                gpu.resize(new_size);
                if engine.width() != new_size.width || engine.height() != new_size.height {
                    let rebuilt = config_with_dims(&self.config, new_size.width, new_size.height);
                    *engine = Engine::new(rebuilt);
                    log::info!(
                        "engine rebuilt at {}x{} (seed preserved)",
                        new_size.width,
                        new_size.height
                    );
                }
                window.request_redraw();
            }

            WindowEvent::RedrawRequested => {
                let frame_output = engine.frame();
                gpu.render(frame_output);
                window.request_redraw();
            }

            _ => {}
        }
    }
}

fn config_with_dims(base: &Config, width: u32, height: u32) -> Config {
    let mut c = base.clone();
    c.width = width;
    c.height = height;
    c
}
