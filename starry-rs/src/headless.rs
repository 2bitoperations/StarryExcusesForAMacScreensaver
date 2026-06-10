//! Headless single-frame rendering: spin up wgpu without a window, draw
//! the same scene the windowed shell would draw, copy the framebuffer back
//! to the CPU, and write it to a PNG.
//!
//! Why this exists:
//!  - Visual verification from environments without display access (CI,
//!    sandboxed shells).
//!  - Foundation for the deterministic golden-image visual-diff tests
//!    planned for Phase 6 — the seeded `generate_default_stars` produces
//!    byte-stable output, so a saved reference PNG can be diffed against
//!    future runs.

use std::error::Error;
use std::path::Path;

use pollster::FutureExt as _;

use crate::scene::{CLEAR_COLOR, SPRITE_CAPACITY, generate_default_stars};
use crate::sprite::SpriteRenderer;

/// Mirror the windowed swapchain choice (wgpu picks an sRGB surface format
/// via `is_srgb`) so the headless render is colorimetrically identical to
/// what a real window would display.
const TEXTURE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

/// Render one frame of the default scene at the given resolution and write
/// the result to `path` as an 8-bit RGBA PNG.
pub fn dump_png(path: &Path, width: u32, height: u32) -> Result<(), Box<dyn Error>> {
    dump_png_async(path, width, height).block_on()
}

async fn dump_png_async(path: &Path, width: u32, height: u32) -> Result<(), Box<dyn Error>> {
    assert!(width > 0 && height > 0, "headless dimensions must be positive");

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

    // RENDER_ATTACHMENT lets us draw into the texture; COPY_SRC lets us
    // pull the result back through `copy_texture_to_buffer`.
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

    let mut sprites = SpriteRenderer::new(&device, TEXTURE_FORMAT, SPRITE_CAPACITY);
    sprites.set_viewport(&queue, width as f32, height as f32);
    let stars = generate_default_stars(width, height);
    sprites.set_instances(&queue, &stars);

    // Texture-to-buffer copies require each row to be padded to
    // `COPY_BYTES_PER_ROW_ALIGNMENT` (256 on every backend). We pad on copy
    // and strip the padding back off before handing bytes to the PNG encoder.
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
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("headless scene pass"),
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
        sprites.draw(&mut pass);
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

    // `map_async` is callback-driven; we forward the result through a
    // channel and use `poll(Wait)` to drive the device until the mapping
    // completes (no winit event loop here to do it for us).
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
