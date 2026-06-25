//! Benchmark harness: spin up wgpu without a window, drive a real
//! `Engine` + `GpuPipelines` through N frames at a fixed dt, measure
//! per-frame wall-clock timings + total process CPU consumption, print a
//! summary to stdout, and append one markdown row to
//! `starry-rs/bench-results.md`.
//!
//! Why this exists (vs. just eyeballing the windowed shell):
//!  - **Reproducibility.** Same seed + same wall-clock anchor + same dt
//!    every run, so per-frame numbers are directly comparable across
//!    commits. Two runs of the same commit should produce essentially
//!    identical stats.
//!  - **Headless.** Runs in CI / over SSH / in sandboxed shells where
//!    `look_at` and `screencapture` are blocked.
//!  - **Real pipelines.** Uses `GpuPipelines::render_to_view` — the same
//!    code path the windowed shell drives, including all 8 render passes,
//!    decay ping-pong, and the composite. Unlike `headless.rs` (which has
//!    its own ad-hoc per-pass orchestration optimised for the single-frame
//!    PNG-dump case), bench measures what the actual app does.
//!  - **No surface.** Bypassing the surface means the bench is not
//!    throttled by vsync — measured timings reflect the raw CPU+GPU cost
//!    of one frame's worth of work, which is the number we want to drive
//!    down. (Caveat: this also means winit `ControlFlow::Poll` busy-spin
//!    overhead is invisible here; that fix has to be measured separately
//!    using the windowed debug overlay.)
//!
//! Loop structure:
//!   1. GPU bootstrap (instance / adapter / device / queue), Engine +
//!      GpuPipelines construction. Single offscreen `Rgba8UnormSrgb`
//!      texture reused across every frame; we never read it back.
//!   2. One warmup frame (discarded). First frame is always anomalous —
//!      lazy GPU resource init, shader compile, page-in. Keeping it in
//!      the sample would skew max + p99 dramatically.
//!   3. CPU sample + Instant::now() before the timed loop.
//!   4. For each of N frames: `Instant::now()` → `engine.frame_with_dt` →
//!      `pipelines.render_to_view` → `device.poll(Wait)` (so the per-frame
//!      delta includes GPU completion, not just CPU submission) →
//!      `start.elapsed()`.
//!   5. CPU sample + Instant::now() after.
//!   6. Compute mean / p50 / p95 / p99 / max from the sorted Duration vec.
//!      Print stdout summary. Append markdown row.
//!
//! `wall_now` for the engine is anchored at `HEADLESS_NOW_UNIX_SECS` (the
//! same 2024-01-01 UTC literal headless uses) so the moon's screen
//! position + phase fraction and every planet's ephemeris are byte-stable
//! across machines — critical for measuring relative improvements.

use std::error::Error;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use pollster::FutureExt as _;

use crate::config::{Config, HEADLESS_NOW_UNIX_SECS};
use crate::cpu_sample::sample_process_cpu_seconds;
use crate::engine::Engine;
use crate::gpu::GpuPipelines;

/// Same texture format the windowed shell picks (sRGB) so colorimetric
/// behaviour matches what a real frame would do — important because some
/// GPU work scales with format (e.g. sRGB conversion in the blend).
const TEXTURE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

/// Fixed per-frame dt for the bench. 1/60s mirrors a vsync'd 60Hz windowed
/// run, so per-frame timings translate directly to the CPU budget available
/// during one real frame (≈16.67 ms).
const BENCH_DT_SECONDS: f64 = 1.0 / 60.0;

pub fn run_bench(config: &Config) -> Result<(), Box<dyn Error>> {
    run_bench_async(config).block_on()
}

async fn run_bench_async(config: &Config) -> Result<(), Box<dyn Error>> {
    let frames = config.bench_frames.unwrap_or(0);
    if frames == 0 {
        log::warn!("bench: --bench-frames is 0 or unset; nothing to do");
        return Ok(());
    }

    let width = config.width;
    let height = config.height;
    assert!(width > 0 && height > 0, "bench dimensions must be positive");

    log::info!(
        "bench: starting {} frames (+1 warmup) @ {}x{} seed={} dt={:.5}s",
        frames,
        width,
        height,
        config.seed,
        BENCH_DT_SECONDS
    );

    // ---- GPU bootstrap (mirrors headless.rs but no readback) ----
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
        "bench adapter: {} (backend={:?}, device_type={:?})",
        info.name,
        info.backend,
        info.device_type
    );

    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor {
            label: Some("starry-rs bench device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::downlevel_defaults(),
            ..Default::default()
        })
        .await?;

    // Single offscreen render target reused across every frame. No readback
    // (bench doesn't care about pixels, only timings), so just
    // RENDER_ATTACHMENT — no COPY_SRC.
    let target = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("bench target"),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: TEXTURE_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        view_formats: &[],
    });
    let target_view = target.create_view(&wgpu::TextureViewDescriptor::default());

    // Build the real Engine + GpuPipelines. GpuPipelines::new MOVES device
    // and queue, so after this we access them via pipelines.device() /
    // pipelines.queue().
    let mut engine = Engine::new(config.clone());
    let mut pipelines = GpuPipelines::new(device, queue, TEXTURE_FORMAT, width, height, config);

    let base_now = UNIX_EPOCH + Duration::from_secs(HEADLESS_NOW_UNIX_SECS);

    // ---- Warmup frame (discarded) ----
    // First frame is always anomalous — pipeline state-object lazy init,
    // any first-touch shader compile, page-in of cold code paths. Without
    // discarding, max and p99 get blown up by ~10ms+ noise.
    {
        let frame_output = engine.frame_with_dt(BENCH_DT_SECONDS, base_now);
        pipelines.render_to_view(&target_view, frame_output);
        pipelines
            .device()
            .poll(wgpu::PollType::wait_indefinitely())?;
    }

    // ---- Timed loop ----
    // Per-frame deltas include device.poll(Wait), so they reflect
    // CPU+GPU time for the frame, not just CPU submission. That's what we
    // want — both CPU fixes (planet trig cache, scratch reuse) and GPU
    // fixes (bind-group caching, render bundles) should both move this
    // number.
    let mut durations: Vec<Duration> = Vec::with_capacity(frames as usize);
    let cpu_before = sample_process_cpu_seconds();
    let wall_before = Instant::now();

    for i in 0..frames {
        // (i + 1) because frame 0 was the warmup; the timed loop picks up
        // at frame 1 in simulation-time so the wall-clock anchor advances
        // monotonically and moon/planet positions don't snap backwards.
        let wall_now = base_now + Duration::from_secs_f64((i as f64 + 1.0) * BENCH_DT_SECONDS);

        let start = Instant::now();
        let frame_output = engine.frame_with_dt(BENCH_DT_SECONDS, wall_now);
        pipelines.render_to_view(&target_view, frame_output);
        pipelines
            .device()
            .poll(wgpu::PollType::wait_indefinitely())?;
        durations.push(start.elapsed());
    }

    let wall_after = Instant::now();
    let cpu_after = sample_process_cpu_seconds();

    // ---- Aggregate stats ----
    let wall_secs = (wall_after - wall_before).as_secs_f64();
    // If CPU sampling is unavailable on the host (returns None), report 0
    // rather than crashing — the timing data is still useful on its own.
    let cpu_secs = match (cpu_before, cpu_after) {
        (Some(a), Some(b)) => (b - a).max(0.0),
        _ => 0.0,
    };
    let cpu_per_frame_us = (cpu_secs / frames as f64) * 1_000_000.0;

    durations.sort_unstable();
    let n = durations.len();
    let mean_us = durations.iter().map(|d| d.as_secs_f64()).sum::<f64>() / n as f64 * 1_000_000.0;
    let p50_us = pct(&durations, 50);
    let p95_us = pct(&durations, 95);
    let p99_us = pct(&durations, 99);
    let max_us = durations
        .last()
        .map_or(0.0, |d| d.as_secs_f64() * 1_000_000.0);

    // ---- Tag + git hash ----
    // git_hash is always the actual hash (best-effort; "unknown" if git
    // isn't on PATH or this isn't a checkout). `tag` defaults to
    // git_hash+dirty so a run with no explicit --bench-tag is still
    // self-documenting in the markdown table.
    let git_hash = git_short_hash().unwrap_or_else(|| "unknown".to_string());
    let dirty = git_dirty();
    let git_hash_display = if dirty {
        format!("{}+dirty", git_hash)
    } else {
        git_hash.clone()
    };
    let tag = config
        .bench_tag
        .clone()
        .unwrap_or_else(|| git_hash_display.clone());

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // ---- Stdout summary ----
    // println! rather than log:: because this is the developer-facing
    // summary; suppressing it via RUST_LOG would defeat the point.
    println!();
    println!(
        "bench complete: {} frames @ {}x{} seed={} tag={}",
        frames, width, height, config.seed, tag
    );
    println!(
        "  per-frame µs:  mean={:.1}  p50={:.1}  p95={:.1}  p99={:.1}  max={:.1}",
        mean_us, p50_us, p95_us, p99_us, max_us
    );
    println!(
        "  totals:        wall={:.3}s  cpu={:.3}s  cpu/frame={:.1} µs",
        wall_secs, cpu_secs, cpu_per_frame_us
    );
    println!();

    // ---- Append to bench-results.md ----
    let results_path = bench_results_path();
    let needs_header = !results_path.exists();
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&results_path)?;
    if needs_header {
        writeln!(file, "# starry-rs benchmark results")?;
        writeln!(file)?;
        writeln!(
            file,
            "Auto-appended by `--bench-frames N`. Newest rows at the bottom."
        )?;
        writeln!(file)?;
        writeln!(
            file,
            "| timestamp | tag | git_hash | frames | size | seed | mean µs | p50 µs | p95 µs | p99 µs | max µs | wall s | cpu s | cpu/frame µs |"
        )?;
        writeln!(
            file,
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
        )?;
    }
    writeln!(
        file,
        "| {} | {} | {} | {} | {}x{} | {} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.3} | {:.3} | {:.1} |",
        ts,
        tag,
        git_hash_display,
        frames,
        width,
        height,
        config.seed,
        mean_us,
        p50_us,
        p95_us,
        p99_us,
        max_us,
        wall_secs,
        cpu_secs,
        cpu_per_frame_us
    )?;
    log::info!("bench: appended row to {}", results_path.display());

    Ok(())
}

/// Nearest-rank percentile of an already-sorted `Duration` slice, in
/// microseconds. For bench-sized samples (hundreds of frames) the
/// distinction between nearest-rank and linear interpolation is in the
/// noise; nearest-rank is simpler and matches what `cargo bench` and
/// hyperfine print.
fn pct(sorted: &[Duration], p: u32) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * (p as f64 / 100.0)).round() as usize;
    sorted[idx].as_secs_f64() * 1_000_000.0
}

/// Short git hash of HEAD, or None if git is missing / this isn't a
/// checkout. Best-effort — the bench should never fail because of a git
/// hiccup.
fn git_short_hash() -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if s.is_empty() { None } else { Some(s) }
}

/// True iff the working tree has any uncommitted changes. Best-effort —
/// returns false on any error so an unflagged dirty run is at worst a
/// missing `+dirty` suffix, not a crash.
fn git_dirty() -> bool {
    Command::new("git")
        .args(["status", "--porcelain"])
        .output()
        .map(|out| out.status.success() && !out.stdout.is_empty())
        .unwrap_or(false)
}

/// Resolves to `<repo>/starry-rs/bench-results.md` at compile time. The
/// path is baked into the binary, which is fine for an in-tree developer
/// tool. CARGO_MANIFEST_DIR for this crate is `starry-rs/starry-core`, so
/// `..` lands in `starry-rs/`.
fn bench_results_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../bench-results.md")
}
