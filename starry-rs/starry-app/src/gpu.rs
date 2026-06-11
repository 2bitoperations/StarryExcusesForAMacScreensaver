//! Windowed adapter on top of `starry_core::gpu::GpuPipelines`. Owns the
//! winit-facing pieces (Surface, SurfaceConfiguration) that the pure
//! pipeline doesn't need to know about, and delegates the actual rendering
//! work — pipelines, textures, encoder building — into the core crate.
//!
//! Split rationale: keeping `Surface` out of `GpuPipelines` lets the core
//! crate stay window-agnostic (so headless tests, golden-image diffs, and
//! eventually a video-capture mode can all share the same pipeline code
//! without dragging winit into the build graph).

use std::sync::Arc;

use pollster::FutureExt as _;
use starry_core::config::Config;
use starry_core::engine::FrameOutput;
use starry_core::gpu::GpuPipelines;
use winit::{dpi::PhysicalSize, window::Window};

pub struct WindowedGpu {
    surface: wgpu::Surface<'static>,
    surface_config: wgpu::SurfaceConfiguration,
    pipelines: GpuPipelines,
}

impl WindowedGpu {
    pub fn new(window: Arc<Window>, app_config: &Config) -> Self {
        Self::new_async(window, app_config).block_on()
    }

    async fn new_async(window: Arc<Window>, app_config: &Config) -> Self {
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

        // Start from the conservative downlevel defaults but bump the texture
        // dimension caps to whatever the adapter actually supports. Without
        // this, `max_texture_dimension_2d` stays at 2048 and any window
        // larger than 2048px on either axis crashes `Surface::configure`
        // with a validation error. On Apple silicon the adapter limit is
        // 16384, so this effectively removes the crash for all realistic
        // displays.
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("starry-rs device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::downlevel_defaults()
                    .using_resolution(adapter.limits()),
                ..Default::default()
            })
            .await
            .expect("request wgpu device");

        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(wgpu::TextureFormat::is_srgb)
            .unwrap_or(caps.formats[0]);

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: caps.present_modes[0],
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &surface_config);

        let pipelines = GpuPipelines::new(
            device,
            queue,
            format,
            surface_config.width,
            surface_config.height,
            app_config,
        );

        Self {
            surface,
            surface_config,
            pipelines,
        }
    }

    /// Resize the surface and internal FBOs. Returns the size actually used
    /// after clamping to the device's `max_texture_dimension_2d` (so the
    /// caller can keep the simulation `Engine` dimensions in sync). On the
    /// no-op zero-size path, returns the current surface dimensions so the
    /// caller's engine-rebuild check stays correct.
    pub fn resize(&mut self, new_size: PhysicalSize<u32>) -> PhysicalSize<u32> {
        if new_size.width == 0 || new_size.height == 0 {
            return PhysicalSize::new(self.surface_config.width, self.surface_config.height);
        }
        // Defense-in-depth: even though we requested the adapter's full
        // resolution at device creation, clamp here so freakishly large
        // future displays can't panic the app.
        let max_dim = self.pipelines.device().limits().max_texture_dimension_2d;
        let w = new_size.width.min(max_dim);
        let h = new_size.height.min(max_dim);
        if w != new_size.width || h != new_size.height {
            log::warn!(
                "clamping surface from {}x{} to {}x{} (max_texture_dimension_2d = {})",
                new_size.width,
                new_size.height,
                w,
                h,
                max_dim
            );
        }
        self.surface_config.width = w;
        self.surface_config.height = h;
        self.surface
            .configure(self.pipelines.device(), &self.surface_config);
        self.pipelines.resize(w, h);
        PhysicalSize::new(w, h)
    }

    pub fn render(&mut self, frame_output: FrameOutput<'_>) {
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => {
                self.surface
                    .configure(self.pipelines.device(), &self.surface_config);
                t
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface
                    .configure(self.pipelines.device(), &self.surface_config);
                return;
            }
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => {
                return;
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                log::warn!("surface validation error; skipping frame");
                return;
            }
        };

        let swap_view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        self.pipelines.render_to_view(&swap_view, frame_output);

        frame.present();
    }
}
