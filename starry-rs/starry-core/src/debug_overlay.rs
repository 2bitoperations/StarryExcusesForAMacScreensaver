//! Debug overlay: FPS/CPU stats overlay (top-left) and build-info overlay
//! (bottom-right), rendered through a single textured-quad pipeline that
//! reuses the 5×7 glyph atlas for both text and background rectangles.
//!
//! BG rects emit a code-127 (DEL) instance scaled to rect dimensions, since
//! `font::FONT[127]` is reserved as a 5×7 solid-1s block. This means one
//! pipeline + one atlas + one instance buffer handle *both* overlays *and*
//! their backgrounds — no shader branches, no separate BG pipeline.
//!
//! Layout coordinates are TOP-DOWN screen pixels (y=0 = top edge), matching
//! Swift `DebugLayerRenderer.swift` so positioning math ports 1:1. The
//! shader (`debug.wgsl`) flips Y when mapping to bottom-up NDC.

use std::mem;

use bytemuck::{Pod, Zeroable};
use log::warn;
use wgpu::util::DeviceExt as _;

use crate::font::{self, GLYPH_HEIGHT, GLYPH_WIDTH};

/// Atlas width in pixels: 128 ASCII glyphs × 5 px each. Must match
/// `debug.wgsl::ATLAS_WIDTH_PX`.
pub const ATLAS_WIDTH_PX: u32 = 128 * GLYPH_WIDTH as u32;
/// Atlas height in pixels: one row of 7-tall glyphs.
pub const ATLAS_HEIGHT_PX: u32 = GLYPH_HEIGHT as u32;
/// Code 127 (DEL) reserved as the BG-rect sentinel; matches `font::FONT[127]`.
pub const SOLID_BLOCK_CODE: u32 = 127;

/// Render scale applied to each glyph (10×14 px effective at scale 2).
pub const GLYPH_SCALE: f32 = 2.0;
/// Horizontal advance per glyph: tight pack, no gap (`GLYPH_WIDTH * scale`).
pub const GLYPH_ADVANCE_PX: f32 = GLYPH_WIDTH as f32 * GLYPH_SCALE;
/// Line height with a one-source-pixel gap between lines.
pub const LINE_HEIGHT_PX: f32 = (GLYPH_HEIGHT as f32 + 1.0) * GLYPH_SCALE;

/// Margin from screen edge for both overlays (Swift literal: 8 px).
pub const OVERLAY_MARGIN_PX: f32 = 8.0;
/// Horizontal padding inside BG rect around glyph area (Swift `padH`).
pub const OVERLAY_PAD_H_PX: f32 = 8.0;
/// Vertical padding inside BG rect around glyph area (Swift `padV`).
pub const OVERLAY_PAD_V_PX: f32 = 4.0;

/// Stats overlay text tint: fuchsia, premultiplied (α=1 so identity).
pub const STATS_TEXT_TINT: [f32; 4] = [1.0, 0.0, 1.0, 1.0];
/// Stats overlay BG tint: dark purple with α=0.55, RGB premultiplied by α.
pub const STATS_BG_TINT: [f32; 4] = [0.05 * 0.55, 0.0, 0.08 * 0.55, 0.55];

/// Build-info overlay text tint: pure green, premultiplied (α=1 identity).
pub const BUILD_TEXT_TINT: [f32; 4] = [0.0, 1.0, 0.0, 1.0];
/// Build-info overlay BG tint: dark green with α=0.55, RGB premultiplied.
pub const BUILD_BG_TINT: [f32; 4] = [0.0, 0.05 * 0.55, 0.0, 0.55];

/// Per-frame data the engine flattens into instance buffers. Both fields
/// are borrowed slices so no heap allocation occurs on the frame path:
/// `stats_text` borrows from a pre-allocated `String` field on
/// `DebugSmoothers`; `build_info_text` is a `&'static str` compile-time
/// constant (`BUILD_COMMIT`).
#[derive(Debug, Clone, Copy)]
pub struct DebugOverlayFrame<'a> {
    pub stats_text: &'a str,
    pub build_info_text: &'static str,
}

impl Default for DebugOverlayFrame<'static> {
    fn default() -> Self {
        Self {
            stats_text: "",
            build_info_text: "",
        }
    }
}

/// One instanced quad. Same struct draws glyphs and BG rects.
///
/// `_pad` keeps `tint` 16-byte aligned — precautionary, matches
/// `SpriteInstance` so the struct stays storage-buffer-friendly if we
/// ever move overlay layout to a compute pass.
#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct DebugInstance {
    pub position: [f32; 2],
    pub size: [f32; 2],
    pub uv_min: [f32; 2],
    pub _pad: [f32; 2],
    pub tint: [f32; 4],
}

/// Maps a Unicode `char` to its atlas U coordinate (texel-space normalized).
/// Non-ASCII falls to slot 0, which inherits the `MISSING` placeholder.
#[inline]
fn uv_min_for_char(c: char) -> [f32; 2] {
    let code = if (c as u32) < 128 { c as u32 } else { 0 };
    [code as f32 * GLYPH_WIDTH as f32 / ATLAS_WIDTH_PX as f32, 0.0]
}

/// UV origin of the DEL solid-block sentinel (used for BG rects).
#[inline]
fn uv_min_for_solid_block() -> [f32; 2] {
    [
        SOLID_BLOCK_CODE as f32 * GLYPH_WIDTH as f32 / ATLAS_WIDTH_PX as f32,
        0.0,
    ]
}

/// Push one overlay's BG rect + glyph quads to `out`.
fn push_overlay(
    out: &mut Vec<DebugInstance>,
    lines: &[&str],
    bg_x: f32,
    bg_y: f32,
    text_tint: [f32; 4],
    bg_tint: [f32; 4],
) -> (f32, f32) {
    let max_chars = lines.iter().map(|s| s.chars().count()).max().unwrap_or(0);
    let text_w = max_chars as f32 * GLYPH_ADVANCE_PX;
    let text_h = lines.len() as f32 * LINE_HEIGHT_PX;
    let bg_w = text_w + 2.0 * OVERLAY_PAD_H_PX;
    let bg_h = text_h + 2.0 * OVERLAY_PAD_V_PX;

    out.push(DebugInstance {
        position: [bg_x, bg_y],
        size: [bg_w, bg_h],
        uv_min: uv_min_for_solid_block(),
        _pad: [0.0; 2],
        tint: bg_tint,
    });

    let glyph_size = [
        GLYPH_WIDTH as f32 * GLYPH_SCALE,
        GLYPH_HEIGHT as f32 * GLYPH_SCALE,
    ];
    for (line_idx, line) in lines.iter().enumerate() {
        let line_y = bg_y + OVERLAY_PAD_V_PX + line_idx as f32 * LINE_HEIGHT_PX;
        for (glyph_idx, ch) in line.chars().enumerate() {
            // Skip spaces — they're encoded as all-zero in the atlas anyway,
            // so they'd be invisible quads. Saves one instance per space.
            if ch == ' ' {
                continue;
            }
            let gx = bg_x + OVERLAY_PAD_H_PX + glyph_idx as f32 * GLYPH_ADVANCE_PX;
            out.push(DebugInstance {
                position: [gx, line_y],
                size: glyph_size,
                uv_min: uv_min_for_char(ch),
                _pad: [0.0; 2],
                tint: text_tint,
            });
        }
    }

    (bg_w, bg_h)
}

/// Convert frame data + viewport size into a flat list of textured-quad
/// instances ready for the GPU. Stats overlay anchors top-left; build-info
/// anchors bottom-right. Empty text in either field omits that overlay
/// entirely (no instances pushed).
pub fn layout_instances(
    frame: &DebugOverlayFrame<'_>,
    viewport_w: f32,
    viewport_h: f32,
    out: &mut Vec<DebugInstance>,
) {
    out.clear();

    let stats_lines: Vec<&str> = frame.stats_text.lines().collect::<Vec<_>>();
    if !stats_lines.is_empty() {
        push_overlay(
            out,
            &stats_lines,
            OVERLAY_MARGIN_PX,
            OVERLAY_MARGIN_PX,
            STATS_TEXT_TINT,
            STATS_BG_TINT,
        );
    }

    let build_lines: Vec<&str> = frame.build_info_text.lines().collect::<Vec<_>>();
    if !build_lines.is_empty() {
        // Pre-compute the BG size so we know where to anchor the bottom-right.
        let max_chars = build_lines
            .iter()
            .map(|s| s.chars().count())
            .max()
            .unwrap_or(0);
        let text_w = max_chars as f32 * GLYPH_ADVANCE_PX;
        let text_h = build_lines.len() as f32 * LINE_HEIGHT_PX;
        let bg_w = text_w + 2.0 * OVERLAY_PAD_H_PX;
        let bg_h = text_h + 2.0 * OVERLAY_PAD_V_PX;
        let bg_x = (viewport_w - OVERLAY_MARGIN_PX - bg_w).max(0.0);
        let bg_y = (viewport_h - OVERLAY_MARGIN_PX - bg_h).max(0.0);
        push_overlay(
            out,
            &build_lines,
            bg_x,
            bg_y,
            BUILD_TEXT_TINT,
            BUILD_BG_TINT,
        );
    }
}

/// Initial instance capacity. Covers stats (~20 glyphs + BG) + build-info
/// (~15 glyphs + BG) with room for multi-line stats; grows on demand.
const INITIAL_INSTANCE_CAPACITY: u64 = 128;

pub struct DebugOverlayRenderer {
    pipeline: wgpu::RenderPipeline,
    #[allow(dead_code)] // Owned to keep texture alive; only the view is bound.
    atlas: wgpu::Texture,
    #[allow(dead_code)]
    atlas_view: wgpu::TextureView,
    #[allow(dead_code)]
    sampler: wgpu::Sampler,
    viewport_ubo: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    instance_vb: wgpu::Buffer,
    instance_capacity: u64,
    instance_count: u32,
}

impl DebugOverlayRenderer {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        surface_format: wgpu::TextureFormat,
        viewport_w: u32,
        viewport_h: u32,
    ) -> Self {
        // ---- Atlas: build 640×7 R8 from the font table ----
        let mut atlas_bytes = vec![0u8; (ATLAS_WIDTH_PX * ATLAS_HEIGHT_PX) as usize];
        for code in 0u8..128 {
            let glyph = font::glyph_for(code as char);
            for (row, &glyph_row) in glyph.iter().enumerate() {
                for col in 0..GLYPH_WIDTH {
                    let bit = (glyph_row >> (4 - col)) & 1;
                    let lit: u8 = if bit == 1 { 255 } else { 0 };
                    let idx = row * ATLAS_WIDTH_PX as usize
                        + code as usize * GLYPH_WIDTH
                        + col;
                    atlas_bytes[idx] = lit;
                }
            }
        }

        let atlas = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("debug overlay atlas"),
            size: wgpu::Extent3d {
                width: ATLAS_WIDTH_PX,
                height: ATLAS_HEIGHT_PX,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::R8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &atlas,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &atlas_bytes,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                // R8Unorm has no row-alignment requirement, so `ATLAS_WIDTH_PX`
                // bytes/row works even though it's less than 256.
                bytes_per_row: Some(ATLAS_WIDTH_PX),
                rows_per_image: Some(ATLAS_HEIGHT_PX),
            },
            wgpu::Extent3d {
                width: ATLAS_WIDTH_PX,
                height: ATLAS_HEIGHT_PX,
                depth_or_array_layers: 1,
            },
        );
        let atlas_view = atlas.create_view(&wgpu::TextureViewDescriptor::default());

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("debug overlay sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            mipmap_filter: wgpu::MipmapFilterMode::Nearest,
            ..Default::default()
        });

        // ---- Viewport UBO (vec4 padded to 16 bytes) ----
        let viewport_ubo = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("debug overlay viewport ubo"),
            contents: bytemuck::cast_slice(&[viewport_w as f32, viewport_h as f32, 0.0, 0.0]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("debug overlay bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX,
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
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::NonFiltering),
                    count: None,
                },
            ],
        });

        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("debug overlay bg"),
            layout: &bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: viewport_ubo.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&atlas_view),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&sampler),
                },
            ],
        });

        // ---- Pipeline ----
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("debug overlay shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("debug.wgsl").into()),
        });

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("debug overlay pipeline layout"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });

        let instance_layout = wgpu::VertexBufferLayout {
            array_stride: mem::size_of::<DebugInstance>() as u64,
            step_mode: wgpu::VertexStepMode::Instance,
            attributes: &[
                wgpu::VertexAttribute {
                    format: wgpu::VertexFormat::Float32x2,
                    offset: 0,
                    shader_location: 0,
                },
                wgpu::VertexAttribute {
                    format: wgpu::VertexFormat::Float32x2,
                    offset: 8,
                    shader_location: 1,
                },
                wgpu::VertexAttribute {
                    format: wgpu::VertexFormat::Float32x2,
                    offset: 16,
                    shader_location: 2,
                },
                wgpu::VertexAttribute {
                    format: wgpu::VertexFormat::Float32x4,
                    // Skip 8 bytes of `_pad` (offset 24..32) to reach `tint`.
                    offset: 32,
                    shader_location: 3,
                },
            ],
        };

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("debug overlay pipeline"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[instance_layout],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: surface_format,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                strip_index_format: None,
                front_face: wgpu::FrontFace::Ccw,
                cull_mode: None,
                unclipped_depth: false,
                polygon_mode: wgpu::PolygonMode::Fill,
                conservative: false,
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let instance_vb = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("debug overlay instances"),
            size: INITIAL_INSTANCE_CAPACITY * mem::size_of::<DebugInstance>() as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self {
            pipeline,
            atlas,
            atlas_view,
            sampler,
            viewport_ubo,
            bind_group,
            instance_vb,
            instance_capacity: INITIAL_INSTANCE_CAPACITY,
            instance_count: 0,
        }
    }

    pub fn set_viewport(&self, queue: &wgpu::Queue, w: u32, h: u32) {
        queue.write_buffer(
            &self.viewport_ubo,
            0,
            bytemuck::cast_slice(&[w as f32, h as f32, 0.0, 0.0]),
        );
    }

    /// Replace the instance buffer's contents; grows the buffer on demand
    /// (next power of two) if `instances` exceeds the current capacity.
    /// Empty input is fine — sets `instance_count = 0` so `draw` is a no-op.
    pub fn set_instances(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        instances: &[DebugInstance],
    ) {
        let n = instances.len() as u64;
        if n > self.instance_capacity {
            let new_cap = n.next_power_of_two().max(self.instance_capacity * 2);
            warn!(
                "debug overlay instance buffer grew {} -> {} (frame had {} instances)",
                self.instance_capacity, new_cap, n
            );
            self.instance_vb = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("debug overlay instances"),
                size: new_cap * mem::size_of::<DebugInstance>() as u64,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.instance_capacity = new_cap;
        }
        if !instances.is_empty() {
            queue.write_buffer(&self.instance_vb, 0, bytemuck::cast_slice(instances));
        }
        self.instance_count = instances.len() as u32;
    }

    /// Issue the draw call. Caller is responsible for being inside an active
    /// render pass with the correct color attachment.
    pub fn draw(&self, pass: &mut wgpu::RenderPass<'_>) {
        if self.instance_count == 0 {
            return;
        }
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &self.bind_group, &[]);
        pass.set_vertex_buffer(0, self.instance_vb.slice(..));
        pass.draw(0..4, 0..self.instance_count);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atlas_dimensions_are_640x7() {
        assert_eq!(ATLAS_WIDTH_PX, 640);
        assert_eq!(ATLAS_HEIGHT_PX, 7);
    }

    #[test]
    fn solid_block_uv_origin_is_at_del_slot() {
        // DEL=127, so atlas U starts at 127*5/640 = 0.9921875.
        let uv = uv_min_for_solid_block();
        assert!((uv[0] - 0.9921875).abs() < 1e-6);
        assert_eq!(uv[1], 0.0);
    }

    #[test]
    fn glyph_uv_origin_for_zero_char_is_zero_slot() {
        // '0' is ASCII 48, so atlas U = 48*5/640 = 0.375.
        let uv = uv_min_for_char('0');
        assert!((uv[0] - 0.375).abs() < 1e-6);
        assert_eq!(uv[1], 0.0);
    }

    #[test]
    fn layout_emits_expected_instance_count() {
        // "ABC" stats (1 BG + 3 glyphs) + "1234" build (1 BG + 4 glyphs) = 9.
        let frame = DebugOverlayFrame {
            stats_text: "ABC",
            build_info_text: "1234",
        };
        let mut insts = Vec::new();
        layout_instances(&frame, 1280.0, 800.0, &mut insts);
        assert_eq!(insts.len(), 9);
    }

    #[test]
    fn layout_skips_spaces_in_glyph_emission() {
        // "A B" emits BG + 2 glyphs (space is skipped — encoded as all-zero
        // so it'd be invisible anyway, saving an instance per space).
        let frame = DebugOverlayFrame {
            stats_text: "A B",
            build_info_text: "",
        };
        let mut insts = Vec::new();
        layout_instances(&frame, 1280.0, 800.0, &mut insts);
        assert_eq!(insts.len(), 3);
    }

    #[test]
    fn stats_overlay_anchors_top_left() {
        // First instance is the stats BG rect at (margin, margin).
        let frame = DebugOverlayFrame {
            stats_text: "X",
            build_info_text: "",
        };
        let mut insts = Vec::new();
        layout_instances(&frame, 1280.0, 800.0, &mut insts);
        assert_eq!(insts[0].position, [OVERLAY_MARGIN_PX, OVERLAY_MARGIN_PX]);
    }

    #[test]
    fn build_overlay_anchors_bottom_right() {
        let frame = DebugOverlayFrame {
            stats_text: "",
            build_info_text: "X",
        };
        let w = 1280.0;
        let h = 800.0;
        let mut insts = Vec::new();
        layout_instances(&frame, w, h, &mut insts);
        assert_eq!(insts.len(), 2);
        let bg = insts[0];
        // BG bottom-right corner should sit at (W - margin, H - margin).
        let br_x = bg.position[0] + bg.size[0];
        let br_y = bg.position[1] + bg.size[1];
        assert!((br_x - (w - OVERLAY_MARGIN_PX)).abs() < 1e-3);
        assert!((br_y - (h - OVERLAY_MARGIN_PX)).abs() < 1e-3);
    }

    #[test]
    fn empty_frame_emits_zero_instances() {
        let frame = DebugOverlayFrame::default();
        let mut insts = Vec::new();
        layout_instances(&frame, 1280.0, 800.0, &mut insts);
        assert!(insts.is_empty());
    }

    #[test]
    fn debug_instance_size_is_48_bytes() {
        // Padding contract for storage-buffer compat / 16-byte tint alignment.
        assert_eq!(mem::size_of::<DebugInstance>(), 48);
    }
}
