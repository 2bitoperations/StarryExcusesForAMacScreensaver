//! Composite pass: stack one or more decay-layer textures onto a render
//! target in caller-supplied Z-order. Each layer is drawn as a fullscreen
//! triangle with `textureLoad` (1:1 nearest-neighbor fetch) and
//! `PREMULTIPLIED_ALPHA_BLENDING` so brighter layer pixels occlude the
//! darker layers underneath.
//!
//! Bind groups for each layer are pre-built by the caller (`GpuPipelines`)
//! and passed in as `&[&wgpu::BindGroup]`. Each ping-pong `DecayLayer`
//! owns two cached bind groups (one per A/B texture view) and exposes the
//! active one via `active_comp_bg()`; the static skyline layer has a single
//! cached group on `GpuPipelines`. This eliminates all per-frame
//! `create_bind_group` calls on the composite hot path.

pub struct CompositeRenderer {
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
}

impl CompositeRenderer {
    pub fn new(
        device: &wgpu::Device,
        output_format: wgpu::TextureFormat,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("composite shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("composite.wgsl").into()),
        });

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("composite bgl"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            }],
        });

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("composite pipeline layout"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("composite pipeline"),
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

        Self { pipeline, bgl }
    }

    /// Build a single bind group for one texture view. Callers use this
    /// at init time and on resize to pre-build their cached bind groups;
    /// the hot `draw_all` path never calls it.
    pub fn create_bind_group_for_view(
        &self,
        device: &wgpu::Device,
        view: &wgpu::TextureView,
    ) -> wgpu::BindGroup {
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("composite layer bg"),
            layout: &self.bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(view),
            }],
        })
    }

    /// Composite pre-built bind groups onto the bound render target, in
    /// slice order: index 0 is the back layer, index N-1 is the front.
    /// No GPU object creation happens here — bind groups must be built
    /// once (at init / resize) and supplied pre-cached by the caller.
    pub fn draw_all(
        &self,
        pass: &mut wgpu::RenderPass<'_>,
        bind_groups: &[&wgpu::BindGroup],
    ) {
        pass.set_pipeline(&self.pipeline);
        for bg in bind_groups {
            pass.set_bind_group(0, *bg, &[]);
            pass.draw(0..3, 0..1);
        }
    }
}
