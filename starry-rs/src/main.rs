//! starry-rs — Phase 0
//!
//! The smallest possible runnable artifact: a winit window backed by wgpu,
//! clearing each frame to a deep-night-sky color. No simulation yet. This
//! exists purely to prove the foundation is sound on your Mac before we start
//! porting the simulation and renderer.

use std::sync::Arc;

use pollster::FutureExt as _;
use winit::{
    application::ApplicationHandler,
    dpi::PhysicalSize,
    event::WindowEvent,
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    window::{Window, WindowId},
};

/// Deep-night-sky clear color. A hair above pure black so it's obvious the
/// window is alive and clearing each frame (vs. the OS just leaving an empty
/// surface behind).
const CLEAR_COLOR: wgpu::Color = wgpu::Color {
    r: 0.012,
    g: 0.012,
    b: 0.025,
    a: 1.0,
};

/// All persistent GPU state lives here. Created lazily on the first `resumed`
/// event because winit doesn't let us touch the window before then.
struct GpuState {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
}

impl GpuState {
    async fn new(window: Arc<Window>) -> Self {
        let size = window.inner_size();

        let instance = wgpu::Instance::default();

        let surface = instance
            .create_surface(window.clone())
            .expect("create wgpu surface from winit window");

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .expect("request wgpu adapter");

        let info = adapter.get_info();
        log::info!(
            "wgpu adapter: {} (backend={:?}, device_type={:?})",
            info.name,
            info.backend,
            info.device_type
        );

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("starry-rs device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::downlevel_defaults(),
                ..Default::default()
            })
            .await
            .expect("request wgpu device");

        let caps = surface.get_capabilities(&adapter);
        // Prefer an sRGB surface format so colors look right out of the box.
        let format = caps
            .formats
            .iter()
            .copied()
            .find(wgpu::TextureFormat::is_srgb)
            .unwrap_or(caps.formats[0]);

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: caps.present_modes[0],
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        Self {
            surface,
            device,
            queue,
            config,
        }
    }

    fn resize(&mut self, new_size: PhysicalSize<u32>) {
        if new_size.width == 0 || new_size.height == 0 {
            return;
        }
        self.config.width = new_size.width;
        self.config.height = new_size.height;
        self.surface.configure(&self.device, &self.config);
    }

    fn render(&mut self) {
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => {
                // Render this frame anyway, but reconfigure for next time.
                self.surface.configure(&self.device, &self.config);
                t
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface.configure(&self.device, &self.config);
                return;
            }
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => {
                // Skip this frame; the surface isn't ready (e.g. window minimized).
                return;
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                log::warn!("surface validation error; skipping frame");
                return;
            }
        };

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("starry-rs frame encoder"),
            });

        {
            // Single clear pass for now. Phase 1 replaces this with the real
            // sprite + composite pipeline encoding.
            let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clear pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(CLEAR_COLOR),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        frame.present();
    }
}

#[derive(Default)]
struct App {
    window: Option<Arc<Window>>,
    gpu: Option<GpuState>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        // `resumed` can fire multiple times on some platforms (notably mobile).
        // Only initialize once.
        if self.window.is_some() {
            return;
        }

        let window = Arc::new(
            event_loop
                .create_window(
                    Window::default_attributes()
                        .with_title("starry-rs — phase 0")
                        .with_inner_size(PhysicalSize::new(1280, 800)),
                )
                .expect("create winit window"),
        );

        let gpu = GpuState::new(window.clone()).block_on();

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
                // Keep the redraw treadmill going so we render continuously.
                window.request_redraw();
            }

            _ => {}
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    log::info!("starry-rs phase 0 starting — homage to the homage to the homage");

    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(ControlFlow::Poll);

    let mut app = App::default();
    event_loop.run_app(&mut app)?;
    Ok(())
}
