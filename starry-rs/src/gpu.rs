//! Owns the wgpu Surface / Device / Queue, the persistent skyline texture
//! that accumulates all sprite draws (Swift parity — see Skyline.swift's
//! "draw new sprites, never wipe except on periodic clear" model), and the
//! two render pipelines that operate on it (sprite + composite).
//!
//! Per-frame flow:
//!   1. Sprite pass: instanced quads -> skyline_tex (transparent layer).
//!      LoadOp = Clear(LAYER_WIPE_COLOR) if FrameOutput::clear_layer else Load.
//!   2. Composite pass: skyline_tex -> swapchain view via fullscreen tri.
//!      LoadOp = Clear(CLEAR_COLOR), then blend skyline_tex on top
//!      (premultiplied alpha "over"). The clear-every-frame is the Swift
//!      parity choice — see `StarryMetalRenderer.swift:1589-1593`.

use std::sync::Arc;

use pollster::FutureExt as _;
use winit::{dpi::PhysicalSize, window::Window};

use crate::composite::CompositeRenderer;
use crate::config::{CLEAR_COLOR, LAYER_WIPE_COLOR};
use crate::engine::FrameOutput;
use crate::sprite::SpriteRenderer;

pub struct GpuState {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    sprites: SpriteRenderer,
    composite: CompositeRenderer,
    skyline_tex: wgpu::Texture,
    skyline_view: wgpu::TextureView,
}

impl GpuState {
    pub fn new(window: Arc<Window>, sprite_capacity: u64) -> Self {
        Self::new_async(window, sprite_capacity).block_on()
    }

    async fn new_async(window: Arc<Window>, sprite_capacity: u64) -> Self {
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

        let (skyline_tex, skyline_view) =
            create_skyline_target(&device, config.width, config.height, format);

        let sprites = SpriteRenderer::new(&device, format, sprite_capacity);
        sprites.set_viewport(&queue, config.width as f32, config.height as f32);

        let composite = CompositeRenderer::new(&device, format, &skyline_view);

        Self {
            surface,
            device,
            queue,
            config,
            sprites,
            composite,
            skyline_tex,
            skyline_view,
        }
    }

    pub fn resize(&mut self, new_size: PhysicalSize<u32>) {
        if new_size.width == 0 || new_size.height == 0 {
            return;
        }
        self.config.width = new_size.width;
        self.config.height = new_size.height;
        self.surface.configure(&self.device, &self.config);
        self.sprites
            .set_viewport(&self.queue, self.config.width as f32, self.config.height as f32);

        let (tex, view) = create_skyline_target(
            &self.device,
            self.config.width,
            self.config.height,
            self.config.format,
        );
        self.skyline_tex = tex;
        self.skyline_view = view;
        self.composite.rebind(&self.device, &self.skyline_view);
    }

    pub fn render(&mut self, frame_output: FrameOutput<'_>) {
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => {
                self.surface.configure(&self.device, &self.config);
                t
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface.configure(&self.device, &self.config);
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

        self.sprites
            .set_instances(&self.device, &self.queue, frame_output.sprites);

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("starry-rs frame encoder"),
            });

        let sprite_load = if frame_output.clear_layer {
            wgpu::LoadOp::Clear(LAYER_WIPE_COLOR)
        } else {
            wgpu::LoadOp::Load
        };

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("sprite -> skyline_tex"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &self.skyline_view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: sprite_load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            self.sprites.draw(&mut pass);
        }

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("composite skyline_tex -> swapchain"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &swap_view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(CLEAR_COLOR),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            self.composite.draw(&mut pass);
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        frame.present();
    }
}

fn create_skyline_target(
    device: &wgpu::Device,
    width: u32,
    height: u32,
    format: wgpu::TextureFormat,
) -> (wgpu::Texture, wgpu::TextureView) {
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("skyline_tex (persistent)"),
        size: wgpu::Extent3d {
            width: width.max(1),
            height: height.max(1),
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let view = tex.create_view(&wgpu::TextureViewDescriptor::default());
    (tex, view)
}
