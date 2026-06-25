//! Owns the wgpu device/queue and orchestrates the rendering layers each
//! frame. Window-agnostic: the windowed shell (`starry-app`) wraps this in
//! a swapchain adapter, but the same pipeline could just as easily drive
//! an offscreen texture for tests or a future video-capture mode.
//!
//! - **Skyline** (persist-and-wipe): one full-size texture (`skyline_tex`)
//!   that accumulates sprites across frames until the engine fires
//!   `clear_skyline`, at which point its `LoadOp` becomes `Clear` for a
//!   one-frame wipe. Single sprite pipeline in `Over` blend mode.
//!
//! - **Flasher** (decay-in-place, `Over` blend): the warning beacon on
//!   the tallest building. Sprite-emitted every ON frame at full
//!   intensity; the decay layer exponentially fades the pixels during
//!   OFF frames so the OFF half of the blink cycle reads as a warm
//!   incandescent cooldown rather than an instant snap-off. Optional —
//!   allocated only when `config.flasher_period_s > 0.0` (period 0
//!   disables the flasher entirely).
//!
//! - **Satellites** (decay-in-place, `Additive` blend): ping-pong texture
//!   pair so each frame can fade the previous result and additively draw
//!   the new sprites on top. Optional — allocated only when
//!   `config.satellites_enabled`.
//!
//! - **Shooting stars** (decay-in-place, `Additive` blend): same pattern
//!   as satellites, independent ping-pong pair and independent
//!   `DecayRenderer` (one UBO per layer so per-layer half-lives don't
//!   collide via FIFO queue writes — see `decay.rs`). Optional.
//!
//! Per-frame encode order (matches `StarryMetalRenderer.swift` —
//! base → flasher → satellites → shooting → planets → planet-moons → moon):
//!   1. Satellites decay  (read active → write scratch, then swap)
//!   2. Shooting   decay  (same)
//!   3. Flasher    decay  (same)
//!   4. Skyline sprite pass  → `skyline_tex` with conditional Clear
//!   5. Satellites sprite pass  → active view, additive over decayed result
//!   6. Shooting   sprite pass  → active view, additive over decayed result
//!   7. Flasher    sprite pass  → active view, `Over` blend on decayed result
//!   8. Composite pass: clear the caller's target view to `CLEAR_COLOR`,
//!      stack enabled layer views in Z-order [skyline, flasher,
//!      satellites, shooting], then — inside the same render pass — draw
//!      any visible planets via `PlanetRenderer`, then any planet-moon
//!      sprites via the dedicated planet-moons `SpriteRenderer` (Galilean
//!      moons + Titan, `Over` blend), then the moon on top via
//!      `MoonRenderer` (premultiplied alpha throughout).
//!
//! Disabled layers skip their decay+sprite steps entirely and are omitted
//! from the composite layer list — no GPU work, no allocated textures.
//! The moon and planets are themselves optional (gated on
//! `config.moon_enabled` and `config.planets_enabled` respectively): when
//! disabled the matching renderer is never constructed and the draw call
//! is skipped. Planet-moons share a single `SpriteRenderer` gated on
//! `config.planet_moons_enabled`.

use crate::composite::CompositeRenderer;
use crate::config::{CLEAR_COLOR, Config, LAYER_WIPE_COLOR, SPRITE_CAPACITY};
use crate::debug_overlay::{DebugInstance, DebugOverlayRenderer, layout_instances};
use crate::decay::DecayRenderer;
use crate::engine::{FrameOutput, LayerFrame};
use crate::moon_renderer::MoonRenderer;
use crate::planet_renderer::PlanetRenderer;
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
    /// Pre-built composite bind groups: index 0 = view_a as source,
    /// index 1 = view_b as source. Selected each frame by `active_comp_bg`
    /// so the composite pass never calls `create_bind_group`.
    comp_bgs: [wgpu::BindGroup; 2],
}

impl DecayLayer {
    #[allow(clippy::too_many_arguments)]
    fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        width: u32,
        height: u32,
        sprite_capacity: u64,
        blend_mode: BlendMode,
        label: &str,
        composite: &CompositeRenderer,
    ) -> Self {
        let (tex_a, view_a) =
            create_layer_target(device, width, height, format, &format!("{label} A"));
        let (tex_b, view_b) =
            create_layer_target(device, width, height, format, &format!("{label} B"));
        let sprites = SpriteRenderer::new(device, format, sprite_capacity, blend_mode);
        sprites.set_viewport(queue, width as f32, height as f32);
        let decay = DecayRenderer::new(device, format, &view_a, &view_b);
        let comp_bgs = [
            composite.create_bind_group_for_view(device, &view_a),
            composite.create_bind_group_for_view(device, &view_b),
        ];
        Self {
            tex_a,
            view_a,
            tex_b,
            view_b,
            active_is_a: true,
            sprites,
            decay,
            comp_bgs,
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

    /// Return the composite bind group for the currently active texture.
    fn active_comp_bg(&self) -> &wgpu::BindGroup {
        if self.active_is_a {
            &self.comp_bgs[0]
        } else {
            &self.comp_bgs[1]
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn resize(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        width: u32,
        height: u32,
        label: &str,
        composite: &CompositeRenderer,
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
        self.decay
            .rebuild_bind_groups(device, &self.view_a, &self.view_b);
        self.comp_bgs = [
            composite.create_bind_group_for_view(device, &self.view_a),
            composite.create_bind_group_for_view(device, &self.view_b),
        ];
        self.sprites
            .set_viewport(queue, width as f32, height as f32);
    }
}

/// Window-agnostic GPU state: owns the device/queue plus every persistent
/// pipeline, texture, and renderer needed to draw a `FrameOutput`. The
/// caller supplies the target texture view on each `render_to_view` call,
/// which is what lets the same struct power both the windowed shell
/// (swapchain view per frame) and any future test/offscreen path.
pub struct GpuPipelines {
    device: wgpu::Device,
    queue: wgpu::Queue,
    format: wgpu::TextureFormat,
    width: u32,
    height: u32,
    skyline_sprites: SpriteRenderer,
    skyline_tex: wgpu::Texture,
    skyline_view: wgpu::TextureView,
    /// Flasher decay layer. `Some` iff `config.flasher_period_s > 0.0` at
    /// construction (period 0 disables the flasher; no allocation, no work).
    /// Uses `BlendMode::Over` (not Additive like satellites/shooting) so the
    /// beacon snaps to full intensity on ON frames; the decay shader does
    /// all the fade work on OFF frames.
    flasher: Option<DecayLayer>,
    satellites: Option<DecayLayer>,
    shooting: Option<DecayLayer>,
    composite: CompositeRenderer,
    /// Moon renderer. `Some` iff `config.moon_enabled` at construction.
    /// Drawn inside the composite pass after the layer composite, so it
    /// sits on top of everything else in the final image.
    moon: Option<MoonRenderer>,
    /// Planet renderer. `Some` iff `config.planets_enabled` at construction.
    /// Drawn inside the composite pass between the N-layer composite and the
    /// moon — planets sit above skyline/satellite/shooting layers but below
    /// the moon (Swift draw order: planets → planet-moons → moon).
    planets: Option<PlanetRenderer>,
    /// Planet-moon sprite renderer (Galilean moons + Titan). `Some` iff
    /// `config.planet_moons_enabled` at construction. Drawn inside the
    /// composite pass between `planets` and `moon` — Swift parity. Capacity
    /// 5: max concurrent sprites = 4 Galileans + Titan when both Jupiter and
    /// Saturn are visible above the horizon. `BlendMode::Over` matches
    /// Swift's `spriteOver` pipeline.
    planet_moons: Option<SpriteRenderer>,
    /// Debug overlay renderer (FPS/CPU stats + build commit). `Some` iff
    /// `config.debug_overlay_enabled` at construction. Drawn inside the
    /// composite pass *after* the moon so the overlay text sits on top of
    /// everything. Owns its own atlas texture + procedural 5×7 glyph font
    /// + grow-on-demand instance buffer.
    debug_overlay: Option<DebugOverlayRenderer>,
    /// Reusable scratch buffer for debug-overlay glyph instances. Cleared
    /// and refilled each frame by `layout_instances`; avoids a per-frame
    /// heap allocation for the returned `Vec<DebugInstance>`.
    debug_instance_buf: Vec<DebugInstance>,
    /// Pre-built composite bind group for the static skyline layer. Never
    /// ping-pongs so one bind group suffices; rebuilt on resize.
    comp_bg_skyline: wgpu::BindGroup,
}

impl GpuPipelines {
    pub fn new(
        device: wgpu::Device,
        queue: wgpu::Queue,
        format: wgpu::TextureFormat,
        width: u32,
        height: u32,
        app_config: &Config,
    ) -> Self {
        let (skyline_tex, skyline_view) =
            create_layer_target(&device, width, height, format, "skyline");

        let skyline_sprites =
            SpriteRenderer::new(&device, format, SPRITE_CAPACITY, BlendMode::Over);
        skyline_sprites.set_viewport(&queue, width as f32, height as f32);

        // Composite renderer created before the decay layers so it can be
        // passed into DecayLayer::new() for pre-building composite bind groups.
        let composite = CompositeRenderer::new(&device, format);
        let comp_bg_skyline = composite.create_bind_group_for_view(&device, &skyline_view);

        let satellites = app_config.satellites_enabled.then(|| {
            DecayLayer::new(
                &device,
                &queue,
                format,
                width,
                height,
                SPRITE_CAPACITY,
                BlendMode::Additive,
                "satellites",
                &composite,
            )
        });

        let shooting = app_config.shooting_stars_enabled.then(|| {
            DecayLayer::new(
                &device,
                &queue,
                format,
                width,
                height,
                SPRITE_CAPACITY,
                BlendMode::Additive,
                "shooting",
                &composite,
            )
        });

        let flasher = (app_config.flasher_period_s > 0.0).then(|| {
            DecayLayer::new(
                &device,
                &queue,
                format,
                width,
                height,
                1,
                BlendMode::Over,
                "flasher",
                &composite,
            )
        });

        let moon = app_config.moon_enabled.then(|| {
            MoonRenderer::new(
                &device,
                &queue,
                format,
                width,
                app_config.moon_diameter_percent,
            )
        });

        let planets = app_config
            .planets_enabled
            .then(|| PlanetRenderer::new(&device, format));

        let planet_moons = app_config.planet_moons_enabled.then(|| {
            let r = SpriteRenderer::new(&device, format, 5, BlendMode::Over);
            r.set_viewport(&queue, width as f32, height as f32);
            r
        });

        let debug_overlay = app_config
            .debug_overlay_enabled
            .then(|| DebugOverlayRenderer::new(&device, &queue, format, width, height));

        Self {
            device,
            queue,
            format,
            width,
            height,
            skyline_sprites,
            skyline_tex,
            skyline_view,
            flasher,
            satellites,
            shooting,
            composite,
            moon,
            planets,
            planet_moons,
            debug_overlay,
            debug_instance_buf: Vec::with_capacity(128),
            comp_bg_skyline,
        }
    }

    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    pub fn format(&self) -> wgpu::TextureFormat {
        self.format
    }

    /// Reallocate all layer textures at the new resolution. The caller is
    /// responsible for any surface/swapchain reconfiguration that lives
    /// outside this struct (the windowed shell does this in `WindowedGpu`).
    pub fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        self.width = width;
        self.height = height;

        self.skyline_sprites
            .set_viewport(&self.queue, width as f32, height as f32);

        let (tex, view) = create_layer_target(&self.device, width, height, self.format, "skyline");
        self.skyline_tex = tex;
        self.skyline_view = view;
        self.comp_bg_skyline = self
            .composite
            .create_bind_group_for_view(&self.device, &self.skyline_view);

        if let Some(layer) = self.satellites.as_mut() {
            layer.resize(
                &self.device,
                &self.queue,
                self.format,
                width,
                height,
                "satellites",
                &self.composite,
            );
        }
        if let Some(layer) = self.shooting.as_mut() {
            layer.resize(
                &self.device,
                &self.queue,
                self.format,
                width,
                height,
                "shooting",
                &self.composite,
            );
        }
        if let Some(layer) = self.flasher.as_mut() {
            layer.resize(
                &self.device,
                &self.queue,
                self.format,
                width,
                height,
                "flasher",
                &self.composite,
            );
        }
        if let Some(m) = self.moon.as_mut() {
            m.resize(&self.device, &self.queue, width);
        }
        if let Some(r) = self.planet_moons.as_ref() {
            r.set_viewport(&self.queue, width as f32, height as f32);
        }
        if let Some(r) = self.debug_overlay.as_ref() {
            r.set_viewport(&self.queue, width, height);
        }
    }

    /// Encode the full 6-pass per-frame sequence into the caller's target
    /// texture view and submit. The view must be in `format()` and at
    /// least `(width, height)` in size; the caller owns acquiring it
    /// (swapchain `get_current_texture` for windowed, render-attachment
    /// alloc for offscreen) and presenting/reading it back afterward.
    pub fn render_to_view(
        &mut self,
        target_view: &wgpu::TextureView,
        frame_output: FrameOutput<'_>,
    ) {
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
        if let (Some(layer), Some(frame)) = (self.shooting.as_mut(), frame_output.shooting.as_ref())
        {
            layer
                .sprites
                .set_instances(&self.device, &self.queue, frame.sprites);
        }
        if let (Some(layer), Some(frame)) = (self.flasher.as_mut(), frame_output.flasher.as_ref()) {
            layer
                .sprites
                .set_instances(&self.device, &self.queue, frame.sprites);
        }

        if let Some(r) = self.planet_moons.as_mut() {
            r.set_instances(&self.device, &self.queue, frame_output.planet_moons);
        }

        // Stage debug-overlay glyph instances (same write-buffer-before-encode
        // pattern as the sprite renderers above). Skips entirely when either
        // the renderer is disabled or the engine had nothing to report.
        if let (Some(r), Some(frame)) = (
            self.debug_overlay.as_mut(),
            frame_output.debug_overlay.as_ref(),
        ) {
            layout_instances(
                frame,
                self.width as f32,
                self.height as f32,
                &mut self.debug_instance_buf,
            );
            r.set_instances(&self.device, &self.queue, &self.debug_instance_buf);
        }

        // Pre-stage planet GPU resources: ensure_planet rebuilds the per-slot
        // texture + mip chain when the diameter changes (engine init, window
        // resize). Done before encoder creation so all queue.write_texture
        // calls are staged linearly, mirroring the sprite-buffer staging.
        if let Some(pr) = self.planets.as_mut() {
            for (identity, params) in frame_output.planets {
                let diameter = ((params.radius_px as u32) * 2).max(1);
                pr.ensure_planet(&self.device, &self.queue, *identity, diameter);
            }
        }

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("starry-rs frame encoder"),
            });

        // ---- 1-3: Decay passes (run-then-swap so active_view() returns the
        //          freshly faded texture, ready for the matching sprite pass).
        if let (Some(layer), Some(frame)) =
            (self.satellites.as_mut(), frame_output.satellites.as_ref())
        {
            run_decay_layer(layer, &self.queue, &mut encoder, frame);
        }
        if let (Some(layer), Some(frame)) = (self.shooting.as_mut(), frame_output.shooting.as_ref())
        {
            run_decay_layer(layer, &self.queue, &mut encoder, frame);
        }
        if let (Some(layer), Some(frame)) = (self.flasher.as_mut(), frame_output.flasher.as_ref()) {
            run_decay_layer(layer, &self.queue, &mut encoder, frame);
        }

        // ---- 4: Skyline sprite pass (persist-and-wipe).
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

        // ---- 5: Satellites sprite pass (additive on top of decayed result).
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

        // ---- 6: Shooting sprite pass (same shape as satellites).
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

        // ---- 7: Flasher sprite pass (Over on top of decayed result; empty
        //          sprite buffer during OFF frames leaves the fading disc alone).
        if let Some(layer) = self.flasher.as_ref() {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("flasher sprite pass"),
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

        // ---- 8: Composite all enabled layers onto the target view.
        // Layer order [skyline, flasher, satellites, shooting] is the back-to-front
        // Z-order matching Swift's pass order in StarryMetalRenderer.swift.
        // Stack-allocated array — no heap allocation, no create_bind_group.
        let mut comp_bgs: [&wgpu::BindGroup; 4] = [&self.comp_bg_skyline; 4];
        let mut n = 1usize;
        if let Some(l) = self.flasher.as_ref() {
            comp_bgs[n] = l.active_comp_bg();
            n += 1;
        }
        if let Some(l) = self.satellites.as_ref() {
            comp_bgs[n] = l.active_comp_bg();
            n += 1;
        }
        if let Some(l) = self.shooting.as_ref() {
            comp_bgs[n] = l.active_comp_bg();
            n += 1;
        }
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("composite -> target"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target_view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(CLEAR_COLOR),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            self.composite.draw_all(&mut pass, &comp_bgs[..n]);

            if let Some(pr) = self.planets.as_ref()
                && !frame_output.planets.is_empty()
            {
                pr.draw(
                    &self.queue,
                    &mut pass,
                    frame_output.planets,
                    self.width as f32,
                    self.height as f32,
                );
            }

            if let Some(r) = self.planet_moons.as_ref() {
                r.draw(&mut pass);
            }

            if let (Some(m), Some(p)) = (self.moon.as_ref(), frame_output.moon.as_ref()) {
                m.draw(
                    &self.queue,
                    &mut pass,
                    p,
                    self.width as f32,
                    self.height as f32,
                );
            }

            // Debug overlay draws last so glyph text sits on top of every
            // other layer including the moon. Both halves of the pair must be
            // Some for a draw to happen — engine + GPU are gated on the same
            // config flag so in practice they always agree.
            if let (Some(r), Some(_)) = (
                self.debug_overlay.as_ref(),
                frame_output.debug_overlay.as_ref(),
            ) {
                r.draw(&mut pass);
            }
        }

        self.queue.submit(std::iter::once(encoder.finish()));
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
    queue: &wgpu::Queue,
    encoder: &mut wgpu::CommandEncoder,
    frame: &LayerFrame<'_>,
) {
    layer.decay.apply(
        queue,
        encoder,
        layer.active_is_a,
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
