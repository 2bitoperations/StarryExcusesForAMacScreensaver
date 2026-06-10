//! Sprite renderer: one instanced-quad pipeline that draws screen-space
//! points/discs. Phase 2 uses it for stars + building lights + the flasher;
//! later phases extend `SpriteInstance` (shape enum, additive blend, trail
//! data) and reuse the same plumbing. The instance buffer starts at the
//! capacity passed to `new()` and grows on demand if a frame ever exceeds
//! it (next power of two; logged at warn).

use std::mem;

use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt as _;

/// Per-sprite data uploaded to the instance vertex buffer each frame.
///
/// The trailing `_pad` keeps `color` on a 16-byte boundary. Vertex attribute
/// fetches don't strictly require this, but it (1) lets us reuse the struct
/// verbatim if we ever move sprites into a storage buffer (where std430 align
/// rules do apply), and (2) keeps natural-alignment fetches on GPUs that
/// care. 4 bytes per sprite is cheap insurance.
#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct SpriteInstance {
    pub position: [f32; 2],
    pub size: f32,
    pub _pad: f32,
    pub color: [f32; 4],
}

impl SpriteInstance {
    pub fn new(position: [f32; 2], size: f32, color: [f32; 4]) -> Self {
        Self {
            position,
            size,
            _pad: 0.0,
            color,
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct QuadVertex {
    position: [f32; 2],
}

const QUAD_VERTICES: [QuadVertex; 4] = [
    QuadVertex { position: [-0.5, -0.5] },
    QuadVertex { position: [ 0.5, -0.5] },
    QuadVertex { position: [-0.5,  0.5] },
    QuadVertex { position: [ 0.5,  0.5] },
];

pub struct SpriteRenderer {
    pipeline: wgpu::RenderPipeline,
    quad_vb: wgpu::Buffer,
    instance_vb: wgpu::Buffer,
    instance_capacity: u64,
    instance_count: u32,
    viewport_ubo: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
}

impl SpriteRenderer {
    pub fn new(
        device: &wgpu::Device,
        surface_format: wgpu::TextureFormat,
        max_instances: u64,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("sprite shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });

        let viewport_ubo = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sprite viewport ubo"),
            contents: bytemuck::cast_slice(&[0.0f32; 4]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sprite bgl"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sprite bg"),
            layout: &bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: viewport_ubo.as_entire_binding(),
            }],
        });

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sprite pipeline layout"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });

        let quad_layout = wgpu::VertexBufferLayout {
            array_stride: mem::size_of::<QuadVertex>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x2,
                offset: 0,
                shader_location: 0,
            }],
        };

        let instance_layout = wgpu::VertexBufferLayout {
            array_stride: mem::size_of::<SpriteInstance>() as u64,
            step_mode: wgpu::VertexStepMode::Instance,
            attributes: &[
                wgpu::VertexAttribute {
                    format: wgpu::VertexFormat::Float32x2,
                    offset: 0,
                    shader_location: 1,
                },
                wgpu::VertexAttribute {
                    format: wgpu::VertexFormat::Float32,
                    offset: 8,
                    shader_location: 2,
                },
                wgpu::VertexAttribute {
                    format: wgpu::VertexFormat::Float32x4,
                    offset: 16,
                    shader_location: 3,
                },
            ],
        };

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("sprite pipeline"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[quad_layout, instance_layout],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: surface_format,
                    blend: Some(premultiplied_alpha_over()),
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

        let quad_vb = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sprite quad vb"),
            contents: bytemuck::cast_slice(&QUAD_VERTICES),
            usage: wgpu::BufferUsages::VERTEX,
        });

        let instance_vb = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("sprite instance vb"),
            size: max_instances * mem::size_of::<SpriteInstance>() as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self {
            pipeline,
            quad_vb,
            instance_vb,
            instance_capacity: max_instances,
            instance_count: 0,
            viewport_ubo,
            bind_group,
        }
    }

    pub fn set_viewport(&self, queue: &wgpu::Queue, width: f32, height: f32) {
        let data = [width, height, 0.0, 0.0];
        queue.write_buffer(&self.viewport_ubo, 0, bytemuck::cast_slice(&data));
    }

    pub fn set_instances(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        instances: &[SpriteInstance],
    ) {
        let n = instances.len() as u64;
        if n > self.instance_capacity {
            let new_capacity = n.next_power_of_two().max(self.instance_capacity * 2);
            log::warn!(
                "sprite instance buffer growing: {} -> {} (requested {})",
                self.instance_capacity,
                new_capacity,
                n
            );
            self.instance_vb = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("sprite instance vb (grown)"),
                size: new_capacity * mem::size_of::<SpriteInstance>() as u64,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.instance_capacity = new_capacity;
        }
        if !instances.is_empty() {
            queue.write_buffer(&self.instance_vb, 0, bytemuck::cast_slice(instances));
        }
        self.instance_count = instances.len() as u32;
    }

    pub fn draw<'a>(&'a self, pass: &mut wgpu::RenderPass<'a>) {
        if self.instance_count == 0 {
            return;
        }
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &self.bind_group, &[]);
        pass.set_vertex_buffer(0, self.quad_vb.slice(..));
        pass.set_vertex_buffer(1, self.instance_vb.slice(..));
        pass.draw(0..4, 0..self.instance_count);
    }
}

/// Standard "over" compositing with premultiplied source alpha.
/// Pairs with the shader's `vec4(color.rgb * alpha, color.a * alpha)` output.
fn premultiplied_alpha_over() -> wgpu::BlendState {
    wgpu::BlendState {
        color: wgpu::BlendComponent {
            src_factor: wgpu::BlendFactor::One,
            dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
            operation: wgpu::BlendOperation::Add,
        },
        alpha: wgpu::BlendComponent {
            src_factor: wgpu::BlendFactor::One,
            dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
            operation: wgpu::BlendOperation::Add,
        },
    }
}
