//! Composite pass: stack one or more decay-layer textures onto a render
//! target in caller-supplied Z-order. Each layer is drawn as a fullscreen
//! triangle with `textureLoad` (1:1 nearest-neighbor fetch) and
//! `PREMULTIPLIED_ALPHA_BLENDING` so brighter layer pixels occlude the
//! darker layers underneath.
//!
//! Bind groups are rebuilt every `draw_all()` call rather than cached on
//! the renderer. This is intentional: layer texture views ping-pong each
//! frame (decay reads "active" and writes "scratch", then they swap), so
//! the bind groups would need recreation every frame anyway. Building
//! them inline keeps the API stateless and removes the need for a
//! `rebind()` lifecycle hook.

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

    /// Composite each layer view onto the bound render target, in slice
    /// order: index 0 is the back layer, index N-1 is the front. Caller
    /// owns the Z-order decision. Bind groups are built fresh from the
    /// supplied views, so callers can pass ping-pong-swapped views every
    /// frame without ceremony.
    pub fn draw_all(
        &self,
        device: &wgpu::Device,
        pass: &mut wgpu::RenderPass<'_>,
        layer_views: &[&wgpu::TextureView],
    ) {
        // Build all bind groups first, then issue draws. wgpu 29 internally
        // ref-counts bind groups so this local Vec can drop at end-of-fn
        // without invalidating the recorded commands.
        let bind_groups: Vec<wgpu::BindGroup> = layer_views
            .iter()
            .map(|view| {
                device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("composite layer bg"),
                    layout: &self.bgl,
                    entries: &[wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(view),
                    }],
                })
            })
            .collect();

        pass.set_pipeline(&self.pipeline);
        for bg in &bind_groups {
            pass.set_bind_group(0, bg, &[]);
            pass.draw(0..3, 0..1);
        }
    }
}
