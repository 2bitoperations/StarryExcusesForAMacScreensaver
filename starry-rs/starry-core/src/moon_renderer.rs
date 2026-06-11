//! Moon renderer: a single 6-vertex triangle-list pipeline that draws the
//! moon disc with procedural-albedo + Lambertian shading + a phase
//! terminator. Reads the engine's [`MoonParams`] each frame, packs it into
//! the [`MoonUniformsGpu`] UBO (layout matches `moon.wgsl`), and issues
//! one draw call inside the caller-supplied composite render pass with
//! `PREMULTIPLIED_ALPHA_BLENDING`.
//!
//! The albedo texture is regenerated on the CPU (see `moon_texture.rs`)
//! whenever the viewport width changes the derived diameter, so the
//! moon's level of detail tracks the canvas size without the shader
//! having to upsample at sample time. Linear filtering on a slightly
//! oversampled albedo gives a smoother look than nearest sampling
//! directly off the 64×64 base.

use std::mem;

use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt as _;

use crate::moon::{MoonParams, radius_from_percent};
use crate::moon_texture::create_moon_texture;

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
struct MoonUniformsGpu {
    viewport_size: [f32; 2],
    center_px: [f32; 2],
    params0: [f32; 4],
    params1: [f32; 4],
    params2: [f32; 4],
}

const _: () = assert!(mem::size_of::<MoonUniformsGpu>() == 64);

pub struct MoonRenderer {
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    ubo: wgpu::Buffer,
    sampler: wgpu::Sampler,
    #[allow(dead_code)]
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    bind_group: wgpu::BindGroup,
    current_diameter: u32,
    moon_diameter_percent: f64,
}

impl MoonRenderer {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        output_format: wgpu::TextureFormat,
        viewport_width: u32,
        moon_diameter_percent: f64,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("moon shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("moon.wgsl").into()),
        });

        let ubo = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("moon ubo"),
            contents: bytemuck::cast_slice(&[MoonUniformsGpu::zeroed()]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("moon sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::MipmapFilterMode::Nearest,
            ..Default::default()
        });

        let diameter = derive_diameter(viewport_width, moon_diameter_percent);
        let (texture, view) = create_moon_albedo_texture(device, queue, diameter);

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("moon bgl"),
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

        let bind_group = create_bind_group(device, &bgl, &ubo, &view, &sampler);

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("moon pipeline layout"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("moon pipeline"),
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
            ubo,
            sampler,
            texture,
            view,
            bind_group,
            current_diameter: diameter,
            moon_diameter_percent,
        }
    }

    pub fn resize(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, viewport_width: u32) {
        let diameter = derive_diameter(viewport_width, self.moon_diameter_percent);
        if diameter == self.current_diameter {
            return;
        }
        let (tex, view) = create_moon_albedo_texture(device, queue, diameter);
        self.texture = tex;
        self.view = view;
        self.bind_group =
            create_bind_group(device, &self.bgl, &self.ubo, &self.view, &self.sampler);
        self.current_diameter = diameter;
    }

    pub fn draw(
        &self,
        queue: &wgpu::Queue,
        pass: &mut wgpu::RenderPass<'_>,
        params: &MoonParams,
        viewport_w: f32,
        viewport_h: f32,
    ) {
        let uniforms = MoonUniformsGpu {
            viewport_size: [viewport_w, viewport_h],
            center_px: params.center_px,
            params0: [
                params.radius_px,
                params.phase_fraction,
                params.bright_brightness,
                params.dark_brightness,
            ],
            params1: [
                if params.debug_show_mask { 1.0 } else { 0.0 },
                params.waxing_sign,
                0.0,
                0.0,
            ],
            params2: [
                params.terminator_mode as f32,
                params.terminator_width,
                params.terminator_bands as f32,
                0.0,
            ],
        };
        queue.write_buffer(&self.ubo, 0, bytemuck::cast_slice(&[uniforms]));

        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &self.bind_group, &[]);
        pass.draw(0..6, 0..1);
    }
}

fn derive_diameter(viewport_width: u32, percent: f64) -> u32 {
    let radius = radius_from_percent(viewport_width as i32, percent);
    (radius * 2).max(2) as u32
}

fn create_moon_albedo_texture(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    diameter: u32,
) -> (wgpu::Texture, wgpu::TextureView) {
    let pixels = create_moon_texture(diameter as usize);
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("moon albedo"),
        size: wgpu::Extent3d {
            width: diameter,
            height: diameter,
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
            texture: &texture,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        &pixels,
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(diameter),
            rows_per_image: Some(diameter),
        },
        wgpu::Extent3d {
            width: diameter,
            height: diameter,
            depth_or_array_layers: 1,
        },
    );
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    (texture, view)
}

fn create_bind_group(
    device: &wgpu::Device,
    bgl: &wgpu::BindGroupLayout,
    ubo: &wgpu::Buffer,
    view: &wgpu::TextureView,
    sampler: &wgpu::Sampler,
) -> wgpu::BindGroup {
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("moon bg"),
        layout: bgl,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: ubo.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(view),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::Sampler(sampler),
            },
        ],
    })
}
