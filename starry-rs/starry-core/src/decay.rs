//! Decay pass: fade an entire texture toward transparent by multiplying
//! every texel by a per-frame `keep` scalar. This drives the trail effect
//! for self-luminous layers (shooting stars, satellites) — the engine
//! computes `keep = 0.5^(dt/halfLife)` so each layer has an exponential
//! half-life that's independent of frame rate.
//!
//! Ping-pong texture pair: `apply()` reads `src_view` and writes
//! `dst_view`. The caller is responsible for swapping the (active, scratch)
//! assignment between frames so successive frames read the latest faded
//! result.
//!
//! Each `DecayRenderer` owns its own keep-factor UBO, so the engine
//! instantiates one renderer per layer. This is necessary because
//! `queue.write_buffer` writes are sequenced FIFO at submit time — a
//! single shared UBO would have all per-layer passes see only the last
//! write, collapsing distinct half-lives into one.

use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt as _;

/// std140-aligned uniform block for `decay.wgsl`. The trailing padding
/// keeps the struct at 16 bytes — wgpu enforces a 16-byte minimum binding
/// size for uniform buffers on most adapters.
#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
struct DecayUniforms {
    keep: f32,
    _pad: [f32; 3],
}

pub struct DecayRenderer {
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    ubo: wgpu::Buffer,
    /// Cached bind groups: index 0 = view_a as src (used when active_is_a
    /// = true), index 1 = view_b as src (used when active_is_a = false).
    /// Rebuilt on resize via `rebuild_bind_groups`; never recreated on the
    /// hot frame path.
    bind_groups: [wgpu::BindGroup; 2],
}

impl DecayRenderer {
    pub fn new(
        device: &wgpu::Device,
        output_format: wgpu::TextureFormat,
        view_a: &wgpu::TextureView,
        view_b: &wgpu::TextureView,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("decay shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("decay.wgsl").into()),
        });

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("decay bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(
                            std::mem::size_of::<DecayUniforms>() as u64,
                        ),
                    },
                    count: None,
                },
            ],
        });

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("decay pipeline layout"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("decay pipeline"),
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
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
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

        let ubo = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("decay ubo"),
            contents: bytemuck::cast_slice(&[DecayUniforms {
                keep: 1.0,
                _pad: [0.0; 3],
            }]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let bind_groups = build_decay_bind_groups(device, &bgl, &ubo, view_a, view_b);
        DecayRenderer { pipeline, bgl, ubo, bind_groups }
    }

    /// Rebuild the cached bind groups after a resize replaces the texture
    /// views. Must be called before the next `apply` so the bind groups
    /// reference the new views rather than the now-invalid old ones.
    pub fn rebuild_bind_groups(
        &mut self,
        device: &wgpu::Device,
        view_a: &wgpu::TextureView,
        view_b: &wgpu::TextureView,
    ) {
        self.bind_groups = build_decay_bind_groups(device, &self.bgl, &self.ubo, view_a, view_b);
    }

    /// Encode one fade pass: read from the active ping-pong buffer
    /// (selected by `active_is_a`), write to `dst_view` scaled by
    /// `keep_factor`. Uses a pre-built bind group — no GPU object
    /// creation on the hot path. Caller does the ping-pong swap.
    pub fn apply(
        &self,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        active_is_a: bool,
        dst_view: &wgpu::TextureView,
        keep_factor: f32,
    ) {
        queue.write_buffer(
            &self.ubo,
            0,
            bytemuck::cast_slice(&[DecayUniforms {
                keep: keep_factor,
                _pad: [0.0; 3],
            }]),
        );

        let bind_group = if active_is_a {
            &self.bind_groups[0]
        } else {
            &self.bind_groups[1]
        };

        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("decay pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: dst_view,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, bind_group, &[]);
        pass.draw(0..3, 0..1);
    }
}

/// Build the two cached bind groups for a `DecayRenderer`. Index 0 binds
/// `view_a` as the source texture (used when `active_is_a = true`); index 1
/// binds `view_b` (used when `active_is_a = false`).
fn build_decay_bind_groups(
    device: &wgpu::Device,
    bgl: &wgpu::BindGroupLayout,
    ubo: &wgpu::Buffer,
    view_a: &wgpu::TextureView,
    view_b: &wgpu::TextureView,
) -> [wgpu::BindGroup; 2] {
    let bg_a = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("decay bg (A-reads)"),
        layout: bgl,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(view_a),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: ubo.as_entire_binding(),
            },
        ],
    });
    let bg_b = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("decay bg (B-reads)"),
        layout: bgl,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(view_b),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: ubo.as_entire_binding(),
            },
        ],
    });
    [bg_a, bg_b]
}
