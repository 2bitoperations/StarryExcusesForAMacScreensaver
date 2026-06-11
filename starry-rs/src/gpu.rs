//! Owns the wgpu Surface / Device / Queue and orchestrates the three
//! rendering layers each frame:
//!
//! - **Skyline** (persist-and-wipe): one full-size texture (`skyline_tex`)
//!   that accumulates sprites across frames until the engine fires
//!   `clear_skyline`, at which point its `LoadOp` becomes `Clear` for a
//!   one-frame wipe. Single sprite pipeline in `Over` blend mode.
//!
//! - **Satellites** (decay-in-place): ping-pong texture pair so each frame
//!   can fade the previous result and additively draw the new sprites on
//!   top. Optional — allocated only when `config.satellites_enabled`.
//!
//! - **Shooting stars** (decay-in-place): same pattern as satellites,
//!   independent ping-pong pair and independent `DecayRenderer` (one UBO
//!   per layer so per-layer half-lives don't collide via FIFO queue
//!   writes — see `decay.rs`). Optional.
//!
//! Per-frame encode order (matches `StarryMetalRenderer.swift` —
//! base → satellites → shooting → moon; moon arrives in Phase 4):
//!   1. Satellites decay  (read active → write scratch, then swap)
//!   2. Shooting   decay  (same)
//!   3. Skyline sprite pass  → `skyline_tex` with conditional Clear
//!   4. Satellites sprite pass  → active view, additive over decayed result
//!   5. Shooting   sprite pass  → active view, additive over decayed result
//!   6. Composite pass: clear swapchain to `CLEAR_COLOR`, then stack the
//!      enabled layer views in Z-order [skyline, satellites, shooting].
//!
//! Disabled layers skip steps 1/4 (or 2/5) entirely and are omitted from
//! the composite layer list — no GPU work, no allocated textures.

use std::sync::Arc;

use pollster::FutureExt as _;
use winit::{dpi::PhysicalSize, window::Window};

use crate::composite::CompositeRenderer;
use crate::config::{CLEAR_COLOR, Config, LAYER_WIPE_COLOR, SPRITE_CAPACITY};
use crate::decay::DecayRenderer;
use crate::engine::{FrameOutput, LayerFrame};
use crate::sprite::{BlendMode, SpriteRenderer};

/// Ping-pong texture pair backing one decay-in-place layer. Each frame
/// the `decay` shader reads from `active` and writes the faded result
/// into `scratch`; we then swap so `scratch` becomes the new `active`,
/// which is what the sprite pass writes additive sprites into and what
/// the composite pass reads from. End result: `active_view()` always
/// names the freshly-rendered texture after `run_decay_layer()` returns.
struct DecayLayer {
    tex_a: wgpu::Texture,
    view_a: wgpu::TextureView,
    tex_b: wgpu::Texture,
    view_b: wgpu::TextureView,
    /// `true` ⇒ `tex_a` holds the latest result, `false` ⇒ `tex_b`. The
    /// matching scratch is the *other* texture. Both textures are
    /// zero-initialised by wgpu on creation, so the first frame's decay
    /// pass reads zeros (which is exactly what we want — no garbage trail).
    active_is_a: bool,
    sprites: SpriteRenderer,
    decay: DecayRenderer,
}

impl DecayLayer {
    fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        width: u32,
        height: u32,
        sprite_capacity: u64,
        label: &str,
    ) -> Self {
        let (tex_a, view_a) =
            create_layer_target(device, width, height, format, &format!("{label} A"));
        let (tex_b, view_b) =
            create_layer_target(device, width, height, format, &format!("{label} B"));
        let sprites = SpriteRenderer::new(device, format, sprite_capacity, BlendMode::Additive);
        sprites.set_viewport(queue, width as f32, height as f32);
        let decay = DecayRenderer::new(device, format);
        Self {
            tex_a,
            view_a,
            tex_b,
            view_b,
            active_is_a: true,
            sprites,
            decay,
        }
    }

    fn active_view(&self) -> &wgpu::TextureView {
        if self.active_is_a {
            &self.view_a
        } else {
            &self.view_b
        }
    }

    fn scratch_view(&self) -> &wgpu::TextureView {
        if self.active_is_a {
            &self.view_b
        } else {
            &self.view_a
        }
    }

    fn swap(&mut self) {
        self.active_is_a = !self.active_is_a;
    }

    fn resize(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        width: u32,
        height: u32,
        label: &str,
    ) {
        let (a, av) = create_layer_target(device, width, height, format, &format!("{label} A"));
        let (b, bv) = create_layer_target(device, width, height, format, &format!("{label} B"));
        self.tex_a = a;
        self.view_a = av;
        self.tex_b = b;
        self.view_b = bv;
        // Reset to a known state: tex_a holds nothing (zero-init), and
        // the next decay pass will read zeros — same as a fresh start.
        self.active_is_a = true;
        self.sprites.set_viewport(queue, width as f32, height as f32);
    }
}

pub struct GpuState {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    skyline_sprites: SpriteRenderer,
    skyline_tex: wgpu::Texture,
    skyline_view: wgpu::TextureView,
    satellites: Option<DecayLayer>,
    shooting: Option<DecayLayer>,
    composite: CompositeRenderer,
}

impl GpuState {
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
            create_layer_target(&device, config.width, config.height, format, "skyline");

        let skyline_sprites =
            SpriteRenderer::new(&device, format, SPRITE_CAPACITY, BlendMode::Over);
        skyline_sprites.set_viewport(&queue, config.width as f32, config.height as f32);

        let satellites = app_config.satellites_enabled.then(|| {
            DecayLayer::new(
                &device,
                &queue,
                format,
                config.width,
                config.height,
                SPRITE_CAPACITY,
                "satellites",
            )
        });

        let shooting = app_config.shooting_stars_enabled.then(|| {
            DecayLayer::new(
                &device,
                &queue,
                format,
                config.width,
                config.height,
                SPRITE_CAPACITY,
                "shooting",
            )
        });

        let composite = CompositeRenderer::new(&device, format);

        Self {
            surface,
            device,
            queue,
            config,
            skyline_sprites,
            skyline_tex,
            skyline_view,
            satellites,
            shooting,
            composite,
        }
    }

    pub fn resize(&mut self, new_size: PhysicalSize<u32>) {
        if new_size.width == 0 || new_size.height == 0 {
            return;
        }
        self.config.width = new_size.width;
        self.config.height = new_size.height;
        self.surface.configure(&self.device, &self.config);

        self.skyline_sprites.set_viewport(
            &self.queue,
            self.config.width as f32,
            self.config.height as f32,
        );

        let (tex, view) = create_layer_target(
            &self.device,
            self.config.width,
            self.config.height,
            self.config.format,
            "skyline",
        );
        self.skyline_tex = tex;
        self.skyline_view = view;

        if let Some(layer) = self.satellites.as_mut() {
            layer.resize(
                &self.device,
                &self.queue,
                self.config.format,
                self.config.width,
                self.config.height,
                "satellites",
            );
        }
        if let Some(layer) = self.shooting.as_mut() {
            layer.resize(
                &self.device,
                &self.queue,
                self.config.format,
                self.config.width,
                self.config.height,
                "shooting",
            );
        }
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

        // Stage all sprite uploads up front. set_instances writes the buffer
        // via queue.write_buffer (FIFO), so doing them before encoding any
        // render passes guarantees each pipeline sees its own data.
        self.skyline_sprites
            .set_instances(&self.device, &self.queue, frame_output.skyline_sprites);

        // Decay-layer renderer ↔ frame_output layer presence is paired at
        // init time (same enabled flag drives both), so as_mut().zip(...)
        // either yields Some-pair or skips the whole pass cleanly.
        if let (Some(layer), Some(frame)) =
            (self.satellites.as_mut(), frame_output.satellites.as_ref())
        {
            layer
                .sprites
                .set_instances(&self.device, &self.queue, frame.sprites);
        }
        if let (Some(layer), Some(frame)) =
            (self.shooting.as_mut(), frame_output.shooting.as_ref())
        {
            layer
                .sprites
                .set_instances(&self.device, &self.queue, frame.sprites);
        }

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("starry-rs frame encoder"),
            });

        // ---- 1+2: Decay passes (run-then-swap so active_view() returns the
        //          freshly faded texture, ready for additive sprite draws).
        if let (Some(layer), Some(frame)) =
            (self.satellites.as_mut(), frame_output.satellites.as_ref())
        {
            run_decay_layer(layer, &self.device, &self.queue, &mut encoder, frame);
        }
        if let (Some(layer), Some(frame)) =
            (self.shooting.as_mut(), frame_output.shooting.as_ref())
        {
            run_decay_layer(layer, &self.device, &self.queue, &mut encoder, frame);
        }

        // ---- 3: Skyline sprite pass (persist-and-wipe).
        let skyline_load = if frame_output.clear_skyline {
            wgpu::LoadOp::Clear(LAYER_WIPE_COLOR)
        } else {
            wgpu::LoadOp::Load
        };
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("skyline sprite pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &self.skyline_view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: skyline_load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            self.skyline_sprites.draw(&mut pass);
        }

        // ---- 4: Satellites sprite pass (additive on top of decayed result).
        if let Some(layer) = self.satellites.as_ref() {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("satellites sprite pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: layer.active_view(),
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        // Load: preserve the just-decayed contents so new
                        // sprites blend additively onto the residual trail.
                        load: wgpu::LoadOp::Load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            layer.sprites.draw(&mut pass);
        }

        // ---- 5: Shooting sprite pass (same shape as satellites).
        if let Some(layer) = self.shooting.as_ref() {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("shooting sprite pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: layer.active_view(),
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            layer.sprites.draw(&mut pass);
        }

        // ---- 6: Composite all enabled layers onto the swapchain.
        // Layer order [skyline, satellites, shooting] is the back-to-front
        // Z-order matching Swift's pass order in StarryMetalRenderer.swift.
        let mut layer_views: Vec<&wgpu::TextureView> = Vec::with_capacity(3);
        layer_views.push(&self.skyline_view);
        if let Some(layer) = self.satellites.as_ref() {
            layer_views.push(layer.active_view());
        }
        if let Some(layer) = self.shooting.as_ref() {
            layer_views.push(layer.active_view());
        }
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("composite -> swapchain"),
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
            self.composite
                .draw_all(&self.device, &mut pass, &layer_views);
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        frame.present();
    }
}

/// Encode one decay layer's "fade then promote" half-step: run the decay
/// shader from the active texture into the scratch, then swap so the
/// caller's subsequent sprite pass targets the freshly-faded result.
/// Sprite encoding is *not* done here — the caller owns the render-pass
/// encoding so it can co-locate all decay passes (encoded first, while
/// no other passes are alive) with all sprite passes (encoded after).
fn run_decay_layer(
    layer: &mut DecayLayer,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    encoder: &mut wgpu::CommandEncoder,
    frame: &LayerFrame<'_>,
) {
    layer.decay.apply(
        device,
        queue,
        encoder,
        layer.active_view(),
        layer.scratch_view(),
        frame.keep_factor,
    );
    layer.swap();
}

fn create_layer_target(
    device: &wgpu::Device,
    width: u32,
    height: u32,
    format: wgpu::TextureFormat,
    label: &str,
) -> (wgpu::Texture, wgpu::TextureView) {
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d {
            width,
            height,
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
