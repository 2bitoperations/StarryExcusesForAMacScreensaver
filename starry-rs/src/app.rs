//! winit app handler: owns the window + GPU + the simulation state.
//! Phase 1 simulation is just a fixed star field generated once at startup.

use std::sync::Arc;

use winit::{
    application::ApplicationHandler,
    dpi::PhysicalSize,
    event::WindowEvent,
    event_loop::ActiveEventLoop,
    window::{Window, WindowId},
};

use crate::{
    gpu::GpuState,
    scene::{DEFAULT_HEIGHT, DEFAULT_WIDTH, SPRITE_CAPACITY, generate_default_stars},
    sprite::SpriteInstance,
};

#[derive(Default)]
pub struct App {
    window: Option<Arc<Window>>,
    gpu: Option<GpuState>,
    stars: Vec<SpriteInstance>,
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
                        .with_title("starry-rs — phase 1")
                        .with_inner_size(PhysicalSize::new(DEFAULT_WIDTH, DEFAULT_HEIGHT)),
                )
                .expect("create winit window"),
        );

        let mut gpu = GpuState::new(window.clone(), SPRITE_CAPACITY);

        let size = window.inner_size();
        self.stars = generate_default_stars(size.width, size.height);
        gpu.upload_sprites(&self.stars);

        self.window = Some(window);
        self.gpu = Some(gpu);
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _id: WindowId,
        event: WindowEvent,
    ) {
        let (Some(gpu), Some(window)) = (self.gpu.as_mut(), self.window.as_ref()) else {
            return;
        };

        match event {
            WindowEvent::CloseRequested => {
                log::info!("window close requested; exiting");
                event_loop.exit();
            }

            WindowEvent::Resized(new_size) => {
                gpu.resize(new_size);
                window.request_redraw();
            }

            WindowEvent::RedrawRequested => {
                gpu.render();
                window.request_redraw();
            }

            _ => {}
        }
    }
}


