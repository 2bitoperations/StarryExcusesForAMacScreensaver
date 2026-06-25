//! C-FFI entry points loaded by the macOS `StarryNight.saver` bundle.
//!
//! The Swift `ScreenSaverView` subclass (`StarrySaverView.swift`) calls
//! these four functions over the lifecycle of the screensaver:
//!
//! ```text
//! starry_create(layer, w, h) → opaque handle   // startAnimation
//! starry_frame(handle)                          // animateOneFrame (60 Hz)
//! starry_resize(handle, w, h)                   // setFrameSize
//! starry_destroy(handle)                        // stopAnimation
//! ```
//!
//! The handle is a heap-allocated [`SaverState`] cast to `*mut c_void`.
//! All four functions are no-ops on a null handle so the Swift side never
//! needs to guard the pointer itself.
//!
//! The entire module is `#[cfg(target_os = "macos")]` so the crate compiles
//! to an empty cdylib on Linux/Windows (where the lint job runs) without
//! touching the Metal-only `SurfaceTargetUnsafe::CoreAnimationLayer` variant.

#![cfg(target_os = "macos")]

use std::ffi::c_void;
use std::time::{Instant, SystemTime};

use pollster::FutureExt as _;
use starry_core::config::Config;
use starry_core::engine::Engine;
use starry_core::gpu::GpuPipelines;

struct SaverState {
    engine: Engine,
    pipelines: GpuPipelines,
    surface: wgpu::Surface<'static>,
    surface_config: wgpu::SurfaceConfiguration,
    last_frame: Instant,
    frame_count: u64,
}

impl SaverState {
    fn render_frame(&mut self) {
        self.frame_count += 1;
        let now = Instant::now();
        let dt = now.duration_since(self.last_frame).as_secs_f64().min(0.25);
        self.last_frame = now;

        let frame_output = self.engine.frame_with_dt(dt, SystemTime::now());

        let result = self.surface.get_current_texture();
        // Log the first 5 frames so Console.app shows whether Metal is
        // handing us drawables.  env_logger writes to stderr which the
        // legacyScreenSaver host captures in the system log.
        if self.frame_count <= 5 {
            let status = match &result {
                wgpu::CurrentSurfaceTexture::Success(_) => "Success",
                wgpu::CurrentSurfaceTexture::Suboptimal(_) => "Suboptimal",
                wgpu::CurrentSurfaceTexture::Outdated => "Outdated",
                wgpu::CurrentSurfaceTexture::Lost => "Lost",
                _ => "Timeout",
            };
            log::warn!(
                "render_frame #{}: get_current_texture={status}",
                self.frame_count
            );
        }
        let frame = match result {
            wgpu::CurrentSurfaceTexture::Success(t) => t,
            wgpu::CurrentSurfaceTexture::Suboptimal(t) => {
                self.surface
                    .configure(self.pipelines.device(), &self.surface_config);
                t
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface
                    .configure(self.pipelines.device(), &self.surface_config);
                return;
            }
            _ => return,
        };

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        self.pipelines.render_to_view(&view, frame_output);
        frame.present();
    }

    fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        let max_dim = self.pipelines.device().limits().max_texture_dimension_2d;
        let w = width.min(max_dim);
        let h = height.min(max_dim);
        self.surface_config.width = w;
        self.surface_config.height = h;
        self.surface
            .configure(self.pipelines.device(), &self.surface_config);
        self.pipelines.resize(w, h);
    }
}

async fn init_async(layer: *mut c_void, width: u32, height: u32) -> Box<SaverState> {
    let instance = wgpu::Instance::default();

    let surface = unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer))
    }
    .expect("create wgpu surface from CAMetalLayer");

    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        })
        .await
        .expect("request wgpu adapter");

    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor {
            label: Some("starry-saver device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
            ..Default::default()
        })
        .await
        .expect("request wgpu device");

    let caps = surface.get_capabilities(&adapter);
    let format = caps
        .formats
        .iter()
        .copied()
        .find(wgpu::TextureFormat::is_srgb)
        .unwrap_or(caps.formats[0]);

    let w = width.max(1);
    let h = height.max(1);

    let surface_config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format,
        width: w,
        height: h,
        present_mode: caps
            .present_modes
            .iter()
            .copied()
            .find(|&m| m == wgpu::PresentMode::Fifo)
            .unwrap_or(caps.present_modes[0]),
        // Prefer Opaque so Core Animation composites our sublayer as fully
        // opaque over the desktop.  PreMultiplied (often caps.alpha_modes[0]
        // on Metal) causes the layer to alpha-blend with whatever is beneath
        // it, which makes it invisible when all clear-color pixels have a=1
        // but the compositor treats the channel as pre-multiplied transparency.
        alpha_mode: caps
            .alpha_modes
            .iter()
            .copied()
            .find(|&m| m == wgpu::CompositeAlphaMode::Opaque)
            .unwrap_or(caps.alpha_modes[0]),
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };
    surface.configure(&device, &surface_config);

    let cfg = Config::default();
    let pipelines = GpuPipelines::new(device, queue, format, w, h, &cfg);
    let engine = Engine::new(cfg);

    Box::new(SaverState {
        engine,
        pipelines,
        surface,
        surface_config,
        last_frame: Instant::now(),
        frame_count: 0,
    })
}

// ---------------------------------------------------------------------------
// C FFI
// ---------------------------------------------------------------------------

/// Initialise the renderer for a `CAMetalLayer*` and return an opaque handle.
/// Called once from `ScreenSaverView -startAnimation`.
#[unsafe(no_mangle)]
pub extern "C" fn starry_create(layer: *mut c_void, width: u32, height: u32) -> *mut c_void {
    env_logger::Builder::from_default_env()
        .filter_level(log::LevelFilter::Warn)
        .try_init()
        .ok();
    if layer.is_null() {
        log::error!("starry_create: null CAMetalLayer pointer");
        return std::ptr::null_mut();
    }
    let state = init_async(layer, width, height).block_on();
    Box::into_raw(state) as *mut c_void
}

/// Render one frame. Called from `ScreenSaverView -animateOneFrame`.
#[unsafe(no_mangle)]
pub extern "C" fn starry_frame(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let state = unsafe { &mut *(handle as *mut SaverState) };
    state.render_frame();
}

/// Notify the renderer of a view resize. Called from `ScreenSaverView -setFrameSize:`.
#[unsafe(no_mangle)]
pub extern "C" fn starry_resize(handle: *mut c_void, width: u32, height: u32) {
    if handle.is_null() {
        return;
    }
    let state = unsafe { &mut *(handle as *mut SaverState) };
    state.resize(width, height);
}

/// Tear down the renderer. Called from `ScreenSaverView -stopAnimation`.
#[unsafe(no_mangle)]
pub extern "C" fn starry_destroy(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(handle as *mut SaverState)) };
}
