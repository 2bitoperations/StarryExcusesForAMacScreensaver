//! Headless single-frame rendering: spin up wgpu without a window, simulate
//! one engine tick at a fixed dt, render the resulting sprites to a texture,
//! copy the texture back to the CPU, write it to a PNG.
//!
//! Why this exists:
//!  - Visual verification from environments without display access (CI,
//!    sandboxed shells).
//!  - Foundation for the deterministic golden-image visual-diff tests
//!    planned for Phase 6 — the seeded `Engine` produces byte-stable
//!    output for a given (seed, width, height, dt), so a saved reference
//!    PNG can be diffed against future runs.
//!
//! Headless skips the windowed shell's ping-pong + persistent-FBO machinery
//! entirely — there's exactly one frame, so cross-frame state is moot.
//! Instead we draw all enabled layers directly into the readback target
//! in Swift's Z-order (skyline → satellites → shooting → moon), each in
//! its own render pass so the per-layer blend mode is preserved:
//!   - Pass 1: clear `CLEAR_COLOR` + skyline sprites (Over)
//!   - Pass 2: load + satellites sprites (Additive)  [if enabled]
//!   - Pass 3: load + shooting   sprites (Additive)  [if enabled]
//!   - Pass 4: load + moon disc  (PremulAlpha)       [if enabled]
//!
//! `HEADLESS_NOW_UNIX_SECS` pins the moon's wall-clock anchor to a fixed
//! reference instant (2024-01-01 UTC) so the moon's screen position and
//! phase fraction are byte-stable across machines.
//!
//! At `dt = HEADLESS_DT_SECONDS = 5.0`, the decay layers' keep_factors
//! collapse to ~0 (default half-lives are 0.10s and 0.18s, so
//! `0.5^(5/0.10) ≈ 0`), which means the windowed shell would also draw
//! essentially just this frame's sprites on a single tick. So even though
//! we skip the decay pass, the pixel output matches the windowed shell's
//! first frame at the same `(seed, w, h, dt)`.

use std::error::Error;
use std::time::{Duration, UNIX_EPOCH};

use pollster::FutureExt as _;

use crate::config::{CLEAR_COLOR, Config, SPRITE_CAPACITY};
use crate::engine::Engine;
use crate::moon_renderer::MoonRenderer;
use crate::sprite::{BlendMode, SpriteRenderer};

/// Mirror the windowed swapchain choice (wgpu picks an sRGB surface format
/// via `is_srgb`) so the headless render is colorimetrically identical to
/// what a real window would display.
const TEXTURE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

/// Simulated time the headless engine advances before rendering. Picked to
/// produce a visually-rich frame (~800 star attempts + ~150 light attempts
/// at the default 1280x800) without crossing into wall-clock territory
/// where the wall-clock `frame()` clamp would kick in. (`frame_with_dt`
/// trusts the caller — see engine.rs.)
const HEADLESS_DT_SECONDS: f64 = 5.0;

/// Wall-clock anchor for clock-driven layers (the moon, currently). Pinned
/// to 2024-01-01 00:00:00 UTC so the moon's screen position and phase
/// fraction are byte-stable across machines, regardless of when the dump
/// is run. Any constant in `[~947182440, +∞)` would work — picked a round
/// year-boundary value for readability.
const HEADLESS_NOW_UNIX_SECS: u64 = 1_704_067_200;

pub fn dump_png(config: &Config) -> Result<(), Box<dyn Error>> {
    dump_png_async(config).block_on()
}

async fn dump_png_async(config: &Config) -> Result<(), Box<dyn Error>> {
    let width = config.width;
    let height = config.height;
    assert!(width > 0 && height > 0, "headless dimensions must be positive");
    let path = config
        .dump_png
        .as_ref()
        .ok_or("dump_png called without --dump-png path")?;

    let instance = wgpu::Instance::default();
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        })
        .await?;

    let info = adapter.get_info();
    log::info!(
        "headless adapter: {} (backend={:?}, device_type={:?})",
        info.name,
        info.backend,
        info.device_type
    );

    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor {
            label: Some("starry-rs headless device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::downlevel_defaults(),
            ..Default::default()
        })
        .await?;

    let target = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("headless target"),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: TEXTURE_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let target_view = target.create_view(&wgpu::TextureViewDescriptor::default());

    let mut engine = Engine::new(config.clone());
    let wall_now = UNIX_EPOCH + Duration::from_secs(HEADLESS_NOW_UNIX_SECS);
    let frame_output = engine.frame_with_dt(HEADLESS_DT_SECONDS, wall_now);

    // Build one SpriteRenderer per layer that actually has data. We construct
    // the optional layer renderers eagerly here (rather than mid-encode)
    // because `set_instances` writes the GPU buffer via `queue.write_buffer`
    // — staging it before any render passes is encoded keeps things linear.
    let mut skyline_sprites =
        SpriteRenderer::new(&device, TEXTURE_FORMAT, SPRITE_CAPACITY, BlendMode::Over);
    skyline_sprites.set_viewport(&queue, width as f32, height as f32);
    skyline_sprites.set_instances(&device, &queue, frame_output.skyline_sprites);

    let satellites_sprites = frame_output.satellites.as_ref().map(|layer| {
        let mut s =
            SpriteRenderer::new(&device, TEXTURE_FORMAT, SPRITE_CAPACITY, BlendMode::Additive);
        s.set_viewport(&queue, width as f32, height as f32);
        s.set_instances(&device, &queue, layer.sprites);
        s
    });

    let shooting_sprites = frame_output.shooting.as_ref().map(|layer| {
        let mut s =
            SpriteRenderer::new(&device, TEXTURE_FORMAT, SPRITE_CAPACITY, BlendMode::Additive);
        s.set_viewport(&queue, width as f32, height as f32);
        s.set_instances(&device, &queue, layer.sprites);
        s
    });

    // MoonRenderer is constructed eagerly here (rather than mid-encode)
    // for the same reason satellite/shooting SpriteRenderers are: its
    // `new()` does `queue.write_texture` for the albedo, and FIFO write
    // ordering vs. the upcoming render passes is easier to reason about
    // when all GPU writes are staged before any encoding begins.
    let moon_renderer = frame_output.moon.as_ref().map(|_| {
        MoonRenderer::new(
            &device,
            &queue,
            TEXTURE_FORMAT,
            width,
            config.moon_diameter_percent,
        )
    });

    log::info!(
        "headless engine tick: dt={:.2}s, clear_skyline={}, skyline={}, satellites={}, shooting={}, moon={}",
        HEADLESS_DT_SECONDS,
        frame_output.clear_skyline,
        frame_output.skyline_sprites.len(),
        frame_output.satellites.as_ref().map_or(0, |l| l.sprites.len()),
        frame_output.shooting.as_ref().map_or(0, |l| l.sprites.len()),
        frame_output.moon.is_some(),
    );

    let bytes_per_pixel = 4u32;
    let unpadded_bytes_per_row = width * bytes_per_pixel;
    let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    let padded_bytes_per_row = unpadded_bytes_per_row.div_ceil(align) * align;
    let readback_size = (padded_bytes_per_row * height) as u64;

    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("headless readback"),
        size: readback_size,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });

    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
        label: Some("headless encoder"),
    });

    // Pass 1: clear + skyline sprites (Over blend).
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("headless skyline pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &target_view,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(CLEAR_COLOR),
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        skyline_sprites.draw(&mut pass);
    }

    // Pass 2: satellites (Additive) layered on top.
    if let Some(s) = &satellites_sprites {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("headless satellites pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &target_view,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        s.draw(&mut pass);
    }

    // Pass 3: shooting stars (Additive) layered on top.
    if let Some(s) = &shooting_sprites {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("headless shooting pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &target_view,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        s.draw(&mut pass);
    }

    // Pass 4: moon disc (PremulAlpha) on top of everything else.
    if let (Some(m), Some(p)) = (&moon_renderer, frame_output.moon.as_ref()) {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("headless moon pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &target_view,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        m.draw(&queue, &mut pass, p, width as f32, height as f32);
    }

    encoder.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo {
            texture: &target,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        wgpu::TexelCopyBufferInfo {
            buffer: &readback,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(padded_bytes_per_row),
                rows_per_image: Some(height),
            },
        },
        wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
    );
    queue.submit(std::iter::once(encoder.finish()));

    let slice = readback.slice(..);
    let (tx, rx) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |result| {
        let _ = tx.send(result);
    });
    device.poll(wgpu::PollType::wait_indefinitely())?;
    rx.recv()??;

    let mapped = slice.get_mapped_range();
    let mut pixels = Vec::with_capacity((unpadded_bytes_per_row * height) as usize);
    for row in 0..height {
        let row_start = (row * padded_bytes_per_row) as usize;
        let row_end = row_start + unpadded_bytes_per_row as usize;
        pixels.extend_from_slice(&mapped[row_start..row_end]);
    }
    drop(mapped);
    readback.unmap();

    let file = std::fs::File::create(path)?;
    let mut png_encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    png_encoder.set_color(png::ColorType::Rgba);
    png_encoder.set_depth(png::BitDepth::Eight);
    let mut writer = png_encoder.write_header()?;
    writer.write_image_data(&pixels)?;

    log::info!("wrote {}x{} RGBA8 PNG to {}", width, height, path.display());
    Ok(())
}
