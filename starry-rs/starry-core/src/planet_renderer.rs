//! Planet renderer: per-planet textured spheres with Lambertian shading and
//! a phase terminator. Mirrors `MoonRenderer` structurally but maintains a
//! `HashMap<PlanetIdentity, PlanetSlot>` of GPU resources — each slot owns
//! its own UBO, mipmapped albedo texture, and bind group, so a single
//! composite pass can issue N draws (up to 8 planets) without UBO write
//! contention.
//!
//! Phase 5a renders the seven non-Saturn planets. Saturn gets the flat
//! placeholder texture from `planet_texture.rs`; the round-disc shader
//! path treats it identically to the others. Full Saturn body + Schlyter
//! ring math lands in Phase 5b as additive shader + UBO work.
//!
//! # Per-planet UBO rationale
//! `queue.write_buffer` calls within one submission ALL execute before any
//! pass commands. A single shared UBO + N draws would therefore render N
//! copies of the LAST write. One UBO per slot sidesteps this entirely, at
//! the cost of `N * 64B` (≤ 512 bytes for all 8 planets — trivial).
//!
//! # Mipmaps
//! Planet textures are mipmapped via a CPU box-filter chain generated at
//! upload time. With a shared all-nearest sampler (mag/min/mipmap) this
//! preserves the retro pixel-art look while killing aliasing shimmer at
//! small render sizes. Chain regeneration only happens inside
//! `ensure_planet`, which is itself rare (engine init + window resize).

use std::collections::HashMap;
use std::mem;

use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt as _;

use crate::planet::{PlanetIdentity, PlanetParams};
use crate::planet_texture::create_planet_texture;

// ---------------------------------------------------------------------------
// GPU UBO — 64-byte mirror of the WGSL `PlanetUniforms` struct in
// `planet.wgsl`. Field order MUST match the shader exactly.
// ---------------------------------------------------------------------------

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
struct PlanetUniformsGpu {
    viewport_size: [f32; 2],
    center_px: [f32; 2],
    /// `(radius_px, phase_fraction, bright_brightness, dark_brightness)`
    params0: [f32; 4],
    /// `(ring_tilt_deg, waxing_sign, ring_rotation_deg, ring_style)`
    /// Phase 5a reads only `.y`; rings populate in 5b.
    params1: [f32; 4],
    /// `(terminator_mode, terminator_width, terminator_bands, texture_aspect)`
    /// Phase 5a `.w` is always 1.0 (round-disc planets).
    params2: [f32; 4],
}

const _: () = assert!(mem::size_of::<PlanetUniformsGpu>() == 64);

impl PlanetUniformsGpu {
    fn from_params(params: &PlanetParams, viewport_w: f32, viewport_h: f32) -> Self {
        Self {
            viewport_size: [viewport_w, viewport_h],
            center_px: params.center_px,
            params0: [
                params.radius_px,
                params.phase_fraction,
                params.bright_brightness,
                params.dark_brightness,
            ],
            params1: [
                params.ring_tilt_deg,
                params.waxing_sign,
                params.ring_rotation_deg,
                params.ring_style as f32,
            ],
            params2: [
                params.terminator_mode as f32,
                params.terminator_width,
                params.terminator_bands as f32,
                params.texture_aspect,
            ],
        }
    }
}

// ---------------------------------------------------------------------------
// Per-planet GPU slot — one of these per active planet identity.
// ---------------------------------------------------------------------------

struct PlanetSlot {
    ubo: wgpu::Buffer,
    // `texture` and `view` are intentionally retained — the bind group
    // borrows them by handle, so dropping them would invalidate the bind
    // group on Vulkan/Metal backends. Marked `dead_code` because nothing
    // outside this module reads them after construction.
    #[allow(dead_code)]
    texture: wgpu::Texture,
    #[allow(dead_code)]
    view: wgpu::TextureView,
    bind_group: wgpu::BindGroup,
    current_diameter: u32,
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

pub struct PlanetRenderer {
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    slots: HashMap<PlanetIdentity, PlanetSlot>,
}

impl PlanetRenderer {
    pub fn new(device: &wgpu::Device, output_format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("planet shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("planet.wgsl").into()),
        });

        // Shared all-nearest sampler — preserves the retro pixel-art look at
        // every mip level. The `Filtering` binding type below is still
        // required: it means "filtering is *allowed*", not "must filter".
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("planet sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            mipmap_filter: wgpu::MipmapFilterMode::Nearest,
            ..Default::default()
        });

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("planet bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("planet pipeline layout"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("planet pipeline"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: output_format,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        Self {
            pipeline,
            bgl,
            sampler,
            slots: HashMap::new(),
        }
    }

    /// Idempotently ensure a slot exists for `identity` at the requested
    /// `diameter`. Rebuilds the slot (texture + mip chain + bind group)
    /// only when missing or when the diameter changed since last call.
    /// Safe to call every frame from `Engine::ensure_planets`; the common
    /// no-op path is a HashMap lookup + diameter compare.
    pub fn ensure_planet(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        identity: PlanetIdentity,
        diameter: u32,
    ) {
        let diameter = diameter.max(1);
        if let Some(slot) = self.slots.get(&identity)
            && slot.current_diameter == diameter
        {
            return;
        }
        let new_slot = build_slot(device, queue, &self.bgl, &self.sampler, identity, diameter);
        self.slots.insert(identity, new_slot);
    }

    /// Draw all the planets the caller passes in, in slice order, into the
    /// caller-supplied composite render pass. Planets without an existing
    /// slot are silently skipped — `ensure_planet` must have been called
    /// for that identity at least once. Slice order determines stacking
    /// when planets overlap (rare in practice — they usually occupy
    /// distinct sky positions).
    pub fn draw(
        &self,
        queue: &wgpu::Queue,
        pass: &mut wgpu::RenderPass<'_>,
        planets: &[(PlanetIdentity, PlanetParams)],
        viewport_w: f32,
        viewport_h: f32,
    ) {
        if planets.is_empty() {
            return;
        }
        pass.set_pipeline(&self.pipeline);
        for (identity, params) in planets {
            let Some(slot) = self.slots.get(identity) else {
                continue;
            };
            let uniforms = PlanetUniformsGpu::from_params(params, viewport_w, viewport_h);
            queue.write_buffer(&slot.ubo, 0, bytemuck::cast_slice(&[uniforms]));
            pass.set_bind_group(0, &slot.bind_group, &[]);
            pass.draw(0..6, 0..1);
        }
    }
}

// ---------------------------------------------------------------------------
// Slot construction
// ---------------------------------------------------------------------------

fn build_slot(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    bgl: &wgpu::BindGroupLayout,
    sampler: &wgpu::Sampler,
    identity: PlanetIdentity,
    diameter: u32,
) -> PlanetSlot {
    let base_pixels = create_planet_texture(identity, diameter);
    let mip_levels = mip_level_count_for(diameter);

    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("planet albedo"),
        size: wgpu::Extent3d {
            width: diameter,
            height: diameter,
            depth_or_array_layers: 1,
        },
        mip_level_count: mip_levels,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });

    let mut prev: Vec<u8> = base_pixels;
    let mut prev_size: u32 = diameter;
    upload_mip(queue, &texture, 0, &prev, prev_size);
    for level in 1..mip_levels {
        let next_size = (diameter >> level).max(1);
        let next = box_filter_rgba(&prev, prev_size, next_size);
        upload_mip(queue, &texture, level, &next, next_size);
        prev = next;
        prev_size = next_size;
    }

    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

    let ubo = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("planet slot ubo"),
        contents: bytemuck::cast_slice(&[PlanetUniformsGpu::zeroed()]),
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    });

    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("planet bg"),
        layout: bgl,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: ubo.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(&view),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::Sampler(sampler),
            },
        ],
    });

    PlanetSlot {
        ubo,
        texture,
        view,
        bind_group,
        current_diameter: diameter,
    }
}

fn upload_mip(
    queue: &wgpu::Queue,
    texture: &wgpu::Texture,
    mip_level: u32,
    pixels: &[u8],
    mip_size: u32,
) {
    queue.write_texture(
        wgpu::TexelCopyTextureInfo {
            texture,
            mip_level,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        pixels,
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            // RGBA8 = 4 bytes per pixel. `write_texture` (unlike buffer
            // copies) has no 256-byte row-alignment requirement; wgpu
            // stages internally if the underlying backend needs it.
            bytes_per_row: Some(mip_size * 4),
            rows_per_image: Some(mip_size),
        },
        wgpu::Extent3d {
            width: mip_size,
            height: mip_size,
            depth_or_array_layers: 1,
        },
    );
}

/// `floor(log2(d)) + 1` for `d >= 1`. Examples: 1→1, 2→2, 64→7, 200→8.
/// Returns 1 for `d == 0` so the caller (`ensure_planet`) is robust against
/// the always-clamped-to-1 lower bound.
fn mip_level_count_for(diameter: u32) -> u32 {
    let mut levels = 1u32;
    let mut d = diameter;
    while d > 1 {
        d /= 2;
        levels += 1;
    }
    levels
}

/// CPU 2×2 box-filter downsample for square RGBA8 textures.
///
/// `src_size` is the source side length in pixels (square assumed);
/// `dst_size` should usually be `(src_size / 2).max(1)`, but is taken as a
/// parameter so the caller controls the final stop point at 1×1.
///
/// Edge pixels: when `src_size` is odd or `dst_size * 2 != src_size`, the
/// extra row/column on the high edge gets clamped — the sampled source
/// coordinate is `min(2*dst + k, src_size - 1)`. Keeps the chain valid all
/// the way down to 1×1 even for non-power-of-two diameters.
fn box_filter_rgba(src: &[u8], src_size: u32, dst_size: u32) -> Vec<u8> {
    debug_assert_eq!(src.len(), (src_size as usize) * (src_size as usize) * 4);
    let mut dst = vec![0u8; (dst_size as usize) * (dst_size as usize) * 4];
    let src_size_i = src_size as i32;
    for dy in 0..dst_size as i32 {
        for dx in 0..dst_size as i32 {
            let mut sums = [0u32; 4];
            let mut count = 0u32;
            for ky in 0..2 {
                for kx in 0..2 {
                    let sx = (dx * 2 + kx).min(src_size_i - 1);
                    let sy = (dy * 2 + ky).min(src_size_i - 1);
                    let i = (sy as usize * src_size as usize + sx as usize) * 4;
                    sums[0] += src[i] as u32;
                    sums[1] += src[i + 1] as u32;
                    sums[2] += src[i + 2] as u32;
                    sums[3] += src[i + 3] as u32;
                    count += 1;
                }
            }
            let j = (dy as usize * dst_size as usize + dx as usize) * 4;
            dst[j] = (sums[0] / count) as u8;
            dst[j + 1] = (sums[1] / count) as u8;
            dst[j + 2] = (sums[2] / count) as u8;
            dst[j + 3] = (sums[3] / count) as u8;
        }
    }
    dst
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mip_level_counts_match_powers_of_two() {
        assert_eq!(mip_level_count_for(1), 1);
        assert_eq!(mip_level_count_for(2), 2);
        assert_eq!(mip_level_count_for(4), 3);
        assert_eq!(mip_level_count_for(64), 7);
        // Non-power-of-two: floor(log2(200)) = 7, + 1 = 8.
        assert_eq!(mip_level_count_for(200), 8);
        // Edge: 0 must not loop forever; caller clamps to 1 anyway.
        assert_eq!(mip_level_count_for(0), 1);
    }

    #[test]
    fn box_filter_halves_a_pure_red_square() {
        // 4×4 pure red → 2×2 pure red (4-tap average of identical pixels).
        let src: Vec<u8> = (0..16).flat_map(|_| [255u8, 0, 0, 255]).collect();
        let dst = box_filter_rgba(&src, 4, 2);
        assert_eq!(dst.len(), 16);
        for px in dst.chunks_exact(4) {
            assert_eq!(px, [255, 0, 0, 255]);
        }
    }

    #[test]
    fn box_filter_averages_a_checkerboard_to_grey() {
        // 2×2 checkerboard (W, B, B, W) → 1×1 = mean(255+0+0+255)/4 = 127.
        let src: Vec<u8> = vec![
            255, 255, 255, 255, // (0,0) white
            0, 0, 0, 255, // (1,0) black
            0, 0, 0, 255, // (0,1) black
            255, 255, 255, 255, // (1,1) white
        ];
        let dst = box_filter_rgba(&src, 2, 1);
        assert_eq!(dst, vec![127, 127, 127, 255]);
    }

    #[test]
    fn box_filter_clamps_odd_source_edges() {
        // 3×3 source — high edge gets clamped (no out-of-bounds), result is
        // 1×1 = mean of 4 samples drawn from the top-left 2×2 region.
        let src: Vec<u8> = vec![
            100, 0, 0, 255, // (0,0)
            200, 0, 0, 255, // (1,0)
            50, 0, 0, 255, // (2,0)   <- clamped over from (1,0) for dx=0 path
            150, 0, 0, 255, // (0,1)
            250, 0, 0, 255, // (1,1)
            70, 0, 0, 255, // (2,1)
            80, 0, 0, 255, // (0,2)
            90, 0, 0, 255, // (1,2)
            10, 0, 0, 255, // (2,2)
        ];
        // For dst=(0,0), samples are src[(0,0), (1,0), (0,1), (1,1)] =
        // 100, 200, 150, 250 → mean = 700/4 = 175.
        let dst = box_filter_rgba(&src, 3, 1);
        assert_eq!(dst, vec![175, 0, 0, 255]);
    }

    #[test]
    fn planet_uniforms_gpu_layout_is_64_bytes() {
        assert_eq!(mem::size_of::<PlanetUniformsGpu>(), 64);
    }

    #[test]
    fn from_params_packs_field_order_matching_wgsl() {
        let params = PlanetParams {
            center_px: [100.0, 200.0],
            radius_px: 50.0,
            phase_fraction: 0.7,
            bright_brightness: 1.0,
            dark_brightness: 0.05,
            waxing_sign: -1.0,
            terminator_mode: 1,
            terminator_width: 0.04,
            terminator_bands: 3,
            texture_aspect: 1.0,
            ring_tilt_deg: 12.5,
            ring_rotation_deg: 77.0,
            ring_style: 1,
        };
        let u = PlanetUniformsGpu::from_params(&params, 1280.0, 800.0);
        assert_eq!(u.viewport_size, [1280.0, 800.0]);
        assert_eq!(u.center_px, [100.0, 200.0]);
        // params0 = (radius, phase, bright, dark)
        assert_eq!(u.params0, [50.0, 0.7, 1.0, 0.05]);
        // params1 = (ring_tilt, waxing, ring_rot, ring_style)
        assert_eq!(u.params1, [12.5, -1.0, 77.0, 1.0]);
        // params2 = (term_mode, term_width, term_bands, tex_aspect)
        assert_eq!(u.params2, [1.0, 0.04, 3.0, 1.0]);
    }
}
