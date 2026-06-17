# AI Agents Instructions

This repository contains swift code to implement a screensaver for MacOS that tries to be an homage to the old AfterDark Starry Night screensaver from the late 90s. Rendering layer implemented with Metal.

I always, always, always want you to discuss any changes you want to make (and their tradeoffs, if any,) before actually making them.

This project is supposed to serve as a fun learning test bed for agentic programming, and as such, our tone should always be lighthearted and welcoming.

## File Contents

### Core
 - `StarryExcuseForAView.swift` - Main entrypoint for the screensaver, where the hooks from the OS live, also where configuration options are read into the engine.
 - `StarryEngine.swift` - Orchestrates the overall simulation loop, configuration changes, timing, renderer creation, and per-frame data assembly (sprites, moon params, clears) for GPU or headless rendering. Also emits automatic planet-moon point sprites (Galilean moons + Titan) into the shared sprite path.
 - `Skyline.swift` - Generates and maintains the static structural world state (buildings, flasher geometry, and moon) plus utility methods to sample stars and building light points while managing timed clearing and moon/flasher behavior.

### Simulation Layer Renderers
 - `SkylineCoreRenderer.swift` - Converts the evolving skyline simulation into per-frame sprite instances by time-based spawning of stars, building lights, and an optional flasher using configured per-second rates.
 - `ShootingStarsLayerRenderer.swift` - Simulates shooting stars with randomized trajectories, brightness curves, and configurable spawn rates. Produces additive sprites that leave trails.
 - `SatellitesLayerRenderer.swift` - Simulates satellite point-lights traversing the sky on randomized great-circle-ish paths with configurable speed, brightness, and spawn rates.
 - `MoonLayerRenderer.swift` - Computes the moon's screen position along a traversal arc and its phase angle, producing `MoonParams` for the GPU moon shader.
 - `DebugLayerRenderer.swift` - Generates the FPS counter and CPU usage debug overlay sprites when debug mode is enabled.

### Data Types & Helpers
 - `MetalTypes.swift` - Defines GPU-shared data types: `SpriteInstance`, `SpriteShape`, `MoonUniforms`, `PlanetParams`, `StarryDrawData`, and related enums/structs.
 - `Moon.swift` - Moon phase calculation (based on real-world lunar cycle) and traversal path geometry.
 - `MoonTexture.swift` - Procedural generation of the moon's albedo texture (cratered, noisy lunar surface).
 - `Planet.swift` - Keplerian orbital ephemeris for all 8 planets (Mercury, Venus, Mars, Jupiter, Saturn, Uranus, Neptune, Pluto), altitude/azimuth sky position from a hardcoded observer location, and screen-space mapping with three positioning modes: "random" (always randomised), "hide" (hidden when below horizon), or "randomWhenBelow" (orbital when visible, random otherwise). Positions use a per-engine nonce so "Regenerate Preview" shuffles them. Includes Saturn ring tilt calculation (Schlyter formula) and lightweight circular-orbit helpers for Jupiter/Saturn moon dot positions.
 - `PlanetTexture.swift` - Procedural RGBA texture generation for all 8 planets in a retro pixel-art style: Jupiter (horizontal bands, Great Red Spot, limb darkening, per-pixel noise), Saturn (square body-only texture — rings rendered geometrically in shader), Venus/Mars/Mercury (solid surfaces with atmospheric or weathered effects), and outer planets (gas giants and ice giants with varying detail and color schemes).
 - `Buildings.swift` - Building style definitions and tile patterns used to generate the skyline silhouette.
 - `Points.swift` - Lightweight `Point` and `Color` value types used throughout the simulation.
 - `DebugSprites.swift` - Helper to generate debug outline rectangle sprites for visual debugging.

### GPU Rendering
 - `StarryMetalRenderer.swift` - The Metal rendering pipeline: manages GPU resources, pipelines, offscreen textures, sprite upload, per-frame scene encoding, compositing, and moon rendering. See [METAL_RENDERER_MAP.md](METAL_RENDERER_MAP.md) for an architectural overview.

### Configuration
 - `StarryConfigSheetController.swift` - Handles drawing the screensaver options panel and associated controls, including per-planet size sliders, planetary position mode dropdown, Saturn ring tilt override (Automatic/Manual with angle slider), and planet terminator mode.
 - `StarryDefaultsManager.swift` - Handles storing and fetching screensaver options values. Reasonable default fallback values for each option live here. Accepts an optional `moduleIdentifier` parameter to override the defaults domain.
 - `BuildInfo.swift` - Auto-generated at build time by a Run Script phase. Contains the git commit hash constant `buildCommit`.

### Preview App (`PreviewApp/`)
 - `main.swift` - Entry point for the standalone StarryPreview app.
 - `PreviewAppDelegate.swift` - Creates a borderless window hosting the screensaver view. Reads the user's saved settings from the sandboxed screensaver container (see Known Quirks below) and displays a build-info overlay.
 - `PreviewApp-Info.plist` - Minimal app plist for the preview target.


## Rust + wgpu port (`starry-rs/`)

A cross-platform Rust + wgpu rewrite lives in [`starry-rs/`](starry-rs/). The plan is to eventually retire the Swift codebase on every platform — including macOS — once the Rust side reaches feature parity. Until then the Swift code remains the visual ground-truth and the shipping macOS product, and both trees live happily side by side in this repo.

### Status (Phase 5a — June 2026)
Windowed app and headless `--dump-png` mode both drive a real `Engine` that ports `StarryEngine.swift` + `Skyline.swift` + `SkylineCoreRenderer.swift` + `Buildings.swift` + `ShootingStarsLayerRenderer.swift` + `SatellitesLayerRenderer.swift` + `Moon.swift` + `MoonTexture.swift` + `Planet.swift` + `PlanetTexture.swift`: seeded skyline generation, horizon-weighted stars, building windows with random per-tile light states, rate-clocked sprite emission, periodic clear, **a flashing beacon on the tallest building with `Over`-blended snap-on + exponential decay half-life (default 0.08s, snappy-LED feel)**, **additive shooting-star streaks with decaying trails (`keep = 0.5^(dt/halfLife)`)**, **additive satellite point-lights traversing a flasher-constrained band with their own decay half-life**, a **procedural moon with real-world Julian-day phase math, traversal-arc motion, 3 terminator modes (hard / smooth / banded), and a 64×64-base-albedo R8Unorm texture upsampled per-canvas-width**, and **7 of the 8 procedural planets (Mercury / Venus / Mars / Jupiter / Uranus / Neptune / Pluto — Saturn body + rings deferred to Phase 5b) with Keplerian J2000 ephemeris + alt/az→screen mapping (hardcoded Austin TX observer), 3 positioning modes (random / hide / random-when-below), per-planet RGBA8 procedural textures with mipmap chains generated at upload, nearest-filter sampler for retro pixel-art parity, and a single shared `planet.wgsl` pipeline parameterized by per-planet UBO**. Rendering uses four persistent FBOs (skyline + three ping-pong pairs for flasher/satellites/shooting) orchestrated through an 8-pass per-frame encode (sat decay → shoot decay → flasher decay → skyline sprites → sat sprites → shoot sprites → flasher sprite → composite), with stateless N-layer composite blending in Swift Z-order (skyline → flasher → satellites → shooting), and the **planets + moon drawn inside the composite pass *after* the N-layer composite (premultiplied alpha; planets first, then moon on top)**. Disabling any layer via `--*-enabled false` (or `--flasher-period-s 0`, `--planets-enabled false`) skips GPU resource allocation entirely. CLI surfaces all 50 knobs (12 Phase-2 + 15 Phase-3 + 11 Phase-4 + 12 Phase-5a) via clap with defaults mirroring `StarryDefaultsManager.swift`. Saturn body + rings (5b) and Galilean + Titan planet-moon dots (5c) are next.

**Phase 3.5** split the original single-crate `starry-rs` into a **Cargo workspace** with two members: `starry-core` (library — all simulation + GPU pipelines + WGSL shaders + headless renderer, window-agnostic) and `starry-app` (binary — the thin winit-driven shell that owns the Surface + main event loop + CLI dispatch). Headless SHA `476e74bca9286c4ec046a288e2f567eb4a5109f39544a3c4cf20877439e6c044` is byte-identical pre- and post-split, proving zero-impact refactor.

**Phase 4** added the procedural moon: ported `Moon.swift` (Julian-day phase math + traversal arc + override triangular wave), `MoonTexture.swift` (64×64 base albedo with 7 hardcoded maria + per-pixel hash noise + CPU nearest upsample to per-canvas-width diameter), and `Shaders.metal` lines 152-266 (vertex + fragment with 3 terminator modes + soft-edge feather + debug-colors override). Wall-clock time is now an **injected parameter** (`Engine::frame(wall_now: SystemTime)`) — windowed passes `SystemTime::now()`, headless anchors at hardcoded `HEADLESS_NOW_UNIX_SECS = 1_704_067_200` (2024-01-01 UTC) for byte-stable determinism. Default terminator mode is **`1` (smooth)** in both Rust and Swift — hard mode produced a strong Mach-band perceptual illusion when the moon was large in frame (sharp brightness contrast → eye perceives a dark stripe at the terminator that isn't in the pixels). SHA baseline `986155e2c009a4dbf63227d32c4171d80a43cbb05a5a54852148ac52a752fa34` — different from Phase 3.5 (`476e74bc...`) because the moon is now in frame, as expected.

**Phase 5a** added 7 of the 8 procedural planets (Mercury / Venus / Mars / Jupiter / Uranus / Neptune / Pluto — Saturn body + rings deferred to 5b): ported `Planet.swift` (Keplerian J2000 ephemeris + alt/az→screen mapping with a hardcoded Austin TX observer + per-engine `nonce: u64` rooted in `Config::seed` for deterministic random fallback positions + 3 below-horizon modes [random / hide / random-when-below]) and `PlanetTexture.swift` (7 procedural RGBA8 generators in retro pixel-art style, with a mipmap chain generated at upload time for Swift parity, sampled with `nearest` to preserve the pixel-art look — intentionally different from the moon's `linear` filter). All 7 planets share a single `planet.wgsl` pipeline parameterized by a 13-field per-planet UBO packed into 3 `vec4`s; the cache is keyed by `PlanetIdentity` (8 variants, no Earth) for O(1) per-planet texture lookup and selective regeneration on resize. The composite pass now draws planets *before* the moon (and Phase 5c will slot planet-moons between them) — verified Swift parity against `StarryMetalRenderer.swift:1648/1668/1692`. A follow-up commit landed a 1-line subtractive eps in `decay.wgsl` (`max(s * keep − 1/2048, 0)`) to escape the sRGB-8 quantization fixed point that left a permanent shooting-star trail residue in the windowed app — the math is `N* ≤ floor(0.5 / (1 − keep))` so shoot keep=0.938 stuck at sRGB-8 (visible); eps ≈ 0.000488 linear shifts the rounding outcome at the low end without perceptibly changing brighter values. Headless SHAs: planets-default `bc6fd368…3e2b`; planets-off `986155e2…fa34` (matches Phase-4 baseline byte-for-byte, proving `--planets-enabled false` fully Option-skips planet resources); eps fix is byte-identical for both (single-frame headless skips decay entirely).

See the phased roadmap in [`starry-rs/README.md`](starry-rs/README.md) and the granular engineering scratchpad in [`starry-rs/PORT_PLAN.md`](starry-rs/PORT_PLAN.md).

### File layout (will grow as phases land)

**Workspace root:**
 - `starry-rs/Cargo.toml` - Workspace root (`resolver = "3"`, `members = ["starry-core", "starry-app"]`, `default-members = ["starry-app"]` so `cargo run` from workspace root targets the binary). `[workspace.package]` shares version/edition/license metadata; `[workspace.dependencies]` pins all crate versions in one place. Deps pinned: wgpu 29, winit 0.30, pollster 0.4, log 0.4, env_logger 0.11, rand 0.8, bytemuck 1 (derive), png 0.17, clap 4 (derive). Release profile uses `lto = "thin"` and `codegen-units = 1`.

**`starry-core/` — library crate (window-agnostic; all simulation + GPU pipelines + WGSL + headless):**
 - `starry-rs/starry-core/Cargo.toml` - Library manifest. Deps via `.workspace = true`: wgpu, log, rand, bytemuck, png, clap, pollster (pollster is needed by `headless.rs` for blocking device acquisition).
 - `starry-rs/starry-core/src/lib.rs` - Crate root: 19 `pub mod` declarations (`config`, `types`, `buildings`, `skyline`, `skyline_renderer`, `shooting_stars`, `satellites`, `moon`, `moon_texture`, `moon_renderer`, `planet`, `planet_texture`, `planet_renderer`, `engine`, `gpu`, `sprite`, `decay`, `composite`, `headless`). No re-exports — call sites use explicit paths like `starry_core::config::Config`.
 - `starry-rs/starry-core/src/buildings.rs` - 6 `BuildingStyle` 8×8 tile patterns + `Building` (start_x, start_y, width, height, style, lights_on bitmap) + `contains` + `is_light_on` (samples the style pattern wrapped over the building rectangle).
 - `starry-rs/starry-core/src/skyline.rs` - `Skyline` static world: buildings (Z-ordered topmost-by-`start_x`), per-column `sky_floor` for star rejection sampling, optional flasher on the tallest building, periodic-clear timer, **`building_max_height: i32`** for downstream layers (e.g. ShootingStars `safeMinY`). Key methods: `attempt_star` (single-shot rejection — caller drives the attempt count), `sample_building_light` (bounded ≤ 200 retries unlike Swift's infinite loop), `flasher_state`, `should_clear_now` / `mark_cleared`.
 - `starry-rs/starry-core/src/skyline_renderer.rs` - Per-frame sprite emitter. Accumulates fractional sprite quotas per-second (Swift parity), drains them into instanced `SpriteInstance`s for stars, building lights, and the flasher. `POINT_SPRITE_SIZE = 1.5`.
 - `starry-rs/starry-core/src/shooting_stars.rs` - `ShootingStarsRenderer` ports `ShootingStarsLayerRenderer.swift`. Poisson spawn (per-frame Bernoulli `p = dt/avg`), 18-segment trail interpolation, 15% fade-in over the first 15% of streak length, head-sprite size = thickness. Emits additive `SpriteInstance`s for each active streak per frame; engine pairs with decay layer for the trail effect.
 - `starry-rs/starry-core/src/satellites.rs` - `SatellitesRenderer` ports `SatellitesLayerRenderer.swift`. Exponential next-spawn timer, flasher-constrained spawn band (`y_min = max(building_max_height, flasher_y + r + gap + d/2)`), at most one active satellite at a time. Emits one additive point-sprite per frame; engine pairs with decay layer for the trail effect.
 - `starry-rs/starry-core/src/moon.rs` - Moon phase math (Julian-day → synodic-month age → illuminated fraction + waxing/waning bool) ported from `Moon.swift`. Hardcoded constants `NEW_MOON_EPOCH_UNIX_SECS = 947_182_440.0` (2000-01-06 18:14:00 UTC reference new moon) + `SYNODIC_MONTH_DAYS = 29.530588853`. Traversal-arc position (left→right; `progress = (wall_seconds mod traversal_seconds) / traversal_seconds`; `x = lerp(r, W-r, progress)`, `y = baseY + archH·sin(π·progress)`). Override triangular wave (`p≤0.5 → 2p waxing; p>0.5 → 2-2p waning`). Pub `radius_from_percent(percent, viewport_width) → i32` helper. `MoonParams` GPU-shared struct + `MoonParams::from_frame_state` factory live here too (matches `sprite.rs` hosting `SpriteInstance`). 5 unit tests.
 - `starry-rs/starry-core/src/moon_texture.rs` - Procedural 64×64 base albedo ported from `MoonTexture.swift`: 7 hardcoded maria (Gaussian σ = radius·0.5) + per-pixel SplitMix64 noise + clamp to `[25, 240]` u8 range. CPU `upsample_nearest(src, src_size, dst_size) → Vec<u8>` for diameter-matched output (linear-filter sampler on GPU side smooths the pixel-art look). Pub `create_moon_texture(target_diameter, rng) → Vec<u8>` end-to-end helper. 5 unit tests including deterministic-output verification.
 - `starry-rs/starry-core/src/moon_renderer.rs` - Moon GPU pipeline: render-pipeline + bind-group-layout + 64B `MoonUniformsGpu` UBO (`repr(C)` Pod+Zeroable mirroring WGSL fields exactly) + linear-filter `Sampler` + `R8Unorm` `Texture` + `BindGroup` + `current_diameter: u32` tracker + stashed `moon_diameter_percent: f64`. `new(device, queue, format, viewport_width, &Config)` allocates everything; `resize(device, queue, viewport_width)` no-ops if the computed diameter hasn't changed (otherwise regenerates the upsampled texture + rebinds); `draw(queue, pass, &MoonParams, viewport_w, viewport_h)` writes the UBO via `queue.write_buffer` (FIFO-safe inside a render pass, before submit), binds, draws 6 vertices. **`R8Unorm` has no row-alignment requirement**, so `bytes_per_row: Some(diameter)` works even when `diameter < 256`.
 - `starry-rs/starry-core/src/planet.rs` - Per-planet simulation state ported from `Planet.swift`. `PlanetIdentity` enum (8 variants, no Earth: Mercury / Venus / Mars / Jupiter / Saturn / Uranus / Neptune / Pluto) drives the per-planet texture cache + per-planet UBO writes. Keplerian J2000 ephemeris (semi-major axis, eccentricity, inclination, longitude of ascending node, argument of perihelion, mean anomaly at epoch + per-element drift rates) projects to heliocentric ecliptic XYZ → geocentric → equatorial → topocentric alt/az with a hardcoded **Austin TX observer** (`OBSERVER_LAT_DEG = 30.2672, OBSERVER_LON_DEG = -97.7431`). 3 below-horizon modes: `Random` (always randomized), `Hide` (skip when below), `RandomWhenBelow` (orbital when visible, randomized otherwise). Random fallback positions seed from a per-engine `nonce: u64` rooted in `Config::seed` so `(seed, w, h)` is reproducible across runs. Computes `PlanetParams` (13 fields packed into 3 `vec4`s for the UBO push). Saturn ring-tilt math (Schlyter formula) parked here for 5b. Lightweight circular-orbit helpers for Jupiter/Saturn moon dot positions parked here for 5c.
 - `starry-rs/starry-core/src/planet_texture.rs` - Procedural RGBA8 generators ported from `PlanetTexture.swift`: 7 unique pixel-art textures (Mercury weathered surface; Venus solid atmosphere; Mars red surface with surface noise; Jupiter horizontal bands + Great Red Spot + limb darkening + per-pixel noise; Uranus + Neptune ice-giant gradients; Pluto small + sparse). Saturn body texture parked for 5b. Each generator builds a square RGBA8 buffer at a target resolution, with deterministic SplitMix64-style hashing for noise. **Mipmap chain generated at upload time** (`generate_mipmaps` helper in `planet_renderer.rs`) for Swift parity — small-planet-at-distance scenarios would look bad without mips. Sampled with `nearest` filter (intentionally different from the moon's `linear` filter) to preserve the retro pixel-art look on Jupiter's bands and Mars's surface.
 - `starry-rs/starry-core/src/planet_renderer.rs` - Planet GPU pipeline: render-pipeline + bind-group-layout + 48B `PlanetParamsGpu` UBO (3 × `vec4` packing 13 fields, `repr(C)` Pod+Zeroable mirroring WGSL exactly) + nearest-filter `Sampler` + `HashMap<PlanetIdentity, wgpu::Texture>` keyed by planet identity (O(1) per-planet lookup, selective regeneration on resize). `new(device, queue, format, viewport_w, viewport_h, &Config, rng)` allocates everything + populates the texture cache with mipmap chains for all visible planets; `resize(device, queue, viewport_w, viewport_h, &Config, rng)` regenerates only the planets whose computed diameter changed; `draw_all(queue, pass, &[PlanetParams], viewport_w, viewport_h)` iterates the visible planet list and binds + writes the UBO + draws 6 vertices per planet. `Option<PlanetRenderer>` in `gpu.rs` so `--planets-enabled false` fully skips GPU resource allocation (pipeline, BGL, texture cache, sampler) — not just the per-frame draw call.
 - `starry-rs/starry-core/src/engine.rs` - Simulation orchestrator: owns `Skyline` + `SkylineRenderer` + `Option<SatellitesRenderer>` + `Option<ShootingStarsRenderer>` + `Option<Moon>` + `Vec<Planet>` (empty when `--planets-enabled false`; otherwise holds all 8 `PlanetIdentity::ALL` entries) + per-engine `nonce: u64` rooted in `Config::seed` for deterministic random fallback positions + reused `planet_params_buf` scratch + seeded `StdRng` + dt clock. **Wall-clock time is an injected parameter**: `frame(wall_now: SystemTime)` ticks against wall-clock with `MAX_DT_SECONDS = 0.25` clamp; `frame_with_dt(dt, wall_now)` trusts the caller (no clamp — used by headless at dt=5.0s for visually-rich single-frame output); both delegate to `frame_impl(dt, wall_now)`, which calls `Moon::position`/`Moon::illuminated_fraction` + each `Planet::frame_state` with `wall_now` and builds `MoonParams::from_frame_state(...)` + per-planet `PlanetParams`. Returns `FrameOutput { skyline_sprites, clear_skyline, satellites: Option<LayerFrame>, shooting: Option<LayerFrame>, moon: Option<MoonParams>, planets: &[(PlanetIdentity, PlanetParams)] }` where `LayerFrame { sprites, decay }` bundles the per-layer sprite stream with its decay `keep_factor`.
 - `starry-rs/starry-core/src/gpu.rs` - `GpuPipelines` — **window-agnostic** wgpu pipeline owner. Holds `Device` + `Queue` + `TextureFormat` + skyline `Texture` + `Option<DecayLayer>` for flasher, satellites, and shooting (so `--*-enabled false` and `--flasher-period-s 0` fully skip GPU allocation) + skyline `SpriteRenderer` + `CompositeRenderer` + `Option<MoonRenderer>` (Option-skipped when `--moon-enabled false`) + `Option<PlanetRenderer>` (Option-skipped when `--planets-enabled false`). Constructor `new(device, queue, format, width, height, &Config)`; renders into a caller-supplied `&TextureView` via `render_to_view(target_view, FrameOutput)`. Exposes `device()`/`queue()`/`format()` accessors so `WindowedGpu` doesn't duplicate them. `DecayLayer { tex_a, view_a, tex_b, view_b, active_is_a, sprites, decay, blend_mode }` owns each layer's full ping-pong state plus its sprite blend mode (`Additive` for satellites + shooting; `Over` for flasher — snap-on at ON, exponential fade during OFF). Per-frame 8-pass encode: (1) satellites decay → swap; (2) shooting decay → swap; (3) flasher decay → swap; (4) skyline sprite pass with `LoadOp::Clear(LAYER_WIPE_COLOR)` if `clear_skyline` else `Load`; (5) satellites sprite pass (Additive); (6) shooting sprite pass (Additive); (7) flasher sprite pass (Over) — emits at most one sprite per frame during ON-half; (8) composite pass into the target view `LoadOp::Clear(CLEAR_COLOR)` blending `[skyline, flasher?, satellites?, shooting?]` in Z-order, then drawing planets (premultiplied alpha) and finally the moon disc on top *inside the same composite pass*. Resize rebuilds all textures and resets `active_is_a = true`; `MoonRenderer::resize` and `PlanetRenderer::resize` are delegated. `DecayLayer::new` is now 8-arg (added `blend_mode: BlendMode` + `label: &str`) and carries `#[allow(clippy::too_many_arguments)]` — internal-only with 3 call sites; deemed simpler than a config-struct refactor per the AGENTS.md "simplicity is highly valued" rule.
 - `starry-rs/starry-core/src/sprite.rs` - `SpriteInstance` (POD, `repr(C)`, position + scalar diameter + RGBA) + `BlendMode::{Over, Additive}` enum + `SpriteRenderer::new(device, format, capacity, mode)` (instanced quad pipeline parameterized by blend mode, viewport UBO, **grow-on-demand instance VBO** that resizes to `n.next_power_of_two().max(capacity * 2)` on overflow). Skyline uses Over; satellites + shooting use Additive.
 - `starry-rs/starry-core/src/decay.rs` - `DecayRenderer` fullscreen-quad pass that runs `out = textureLoad(src) * keep_factor` from one texture into another. Per-layer instance owns its own UBO (FIFO `write_buffer` ordering means one renderer per layer avoids overwriting in-flight uniforms). Called by `gpu.rs::run_decay_layer()` which then triggers `DecayLayer::swap()`.
 - `starry-rs/starry-core/src/composite.rs` - `CompositeRenderer`: stateless N-layer compositor. `draw_all(device, pass, &[&TextureView])` builds a temporary bind group per layer view and blends each over the swapchain in slice order with `PREMULTIPLIED_ALPHA_BLENDING`. No caching, no `rebind()` — just rebuild every frame; it's essentially free on the GPU and saves an entire class of bookkeeping bugs.
 - `starry-rs/starry-core/src/headless.rs` - `dump_png(&Config)` — offscreen `Rgba8UnormSrgb` render-to-texture, drives a real `Engine` at fixed `dt = 5.0s` for deterministic byte-stable output. Wall-clock anchored at hardcoded `HEADLESS_NOW_UNIX_SECS = 1_704_067_200` (2024-01-01 UTC) so the moon's phase + position are byte-stable too. Single-frame so it skips the ping-pong machinery entirely (at `dt=5s` the decay layers mathematically collapse to ~0): 6 render passes into the same readback target in Swift Z-order — Pass 1 skyline-Over with `Clear(CLEAR_COLOR)`, Pass 2 flasher-Over with `Load` (if enabled), Pass 3 satellites-Additive with `Load` (if enabled), Pass 4 shooting-Additive with `Load` (if enabled), Pass 5 planets-PremulAlpha with `Load` (if any visible), Pass 6 moon-PremulAlpha with `Load` (if enabled). Padded `copy_texture_to_buffer` readback, writes PNG via the `png` crate. Builds its own device/queue from scratch (not via `GpuPipelines`) so headless stays decoupled from the windowed pipeline API.
 - `starry-rs/starry-core/src/config.rs` - clap-derive `Config` (50 fields: 12 Phase-2 + 15 Phase-3 across `shooting_stars_*` and `satellites_*` + 11 Phase-4 across `moon_*` and `debug_moon_colors` + 12 Phase-5a across `--planets-enabled`, 8 per-planet size flags [`--mercury-size`, `--venus-size`, `--mars-size`, `--jupiter-size`, `--saturn-size`, `--uranus-size`, `--neptune-size`, `--pluto-size`], `--planet-below-horizon-behavior`, `--planet-phase-mode`, `--planet-terminator-mode`; bools use `clap::ArgAction::Set` so `--flag false` disables) + `CLEAR_COLOR` (opaque black sky, per Swift parity) + `LAYER_WIPE_COLOR` (transparent black for the persistent skyline layer's periodic wipe) + `SPRITE_CAPACITY = 131_072` + rate helpers that scale Swift's reference per-second rates by canvas area + `PLANET_TERMINATOR_WIDTH = 0.1` and `PLANET_TERMINATOR_BANDS = 3` hardcoded constants for the planet shader.
 - `starry-rs/starry-core/src/types.rs` - `Color { r, g, b: f32 }` + `Point { x, y: i32, color: Color }` value types + `random_star_color` producing pastel blue/purple/red mixes (matches Swift's `r:[0,0.5] g:[0,0.5] b:[0,1.0]` ranges).
 - `starry-rs/starry-core/src/shader.wgsl` - Sprite vertex (pixel→NDC via viewport UBO, Y-up matching Swift) + fragment (round-disc with soft edge, premultiplied output) shaders.
 - `starry-rs/starry-core/src/decay.wgsl` - Fullscreen-triangle vertex + fragment that samples `src` via `textureLoad`, multiplies by `uniforms.keep`, and **subtracts a tiny eps (`1.0 / 2048.0` ≈ 0.000488 linear) clamped at 0** to escape the sRGB-8 quantization fixed point. Without the eps, sRGB-8 textures hit a stuck residue at low brightness because `round(N × keep) = N` once `N ≤ floor(0.5 / (1 − keep))` — shoot keep=0.938 froze visibly at sRGB-8; eps shifts the rounding outcome at the low end without perceptibly changing brighter values. One per-layer UBO; called once per decay layer per frame.
 - `starry-rs/starry-core/src/moon.wgsl` - Moon vertex (6-vertex NDC quad sized + positioned from `MoonUniformsGpu`) + fragment (round-disc with `r²>1` discard, soft edge `featherLocal = clamp(2/radius, 0.0015, 0.12)`, terminator math `cos_delta = 1 - 2·illum; delta = acos(...); phi = waxing>0 ? PI-delta : delta-PI`, 3 modes [hard step / smooth gradient / banded], bright/dark hemisphere lerp using sampled R8 albedo, debug-colors override). UBO field order = explicit Rust `MoonUniformsGpu` mirror: `viewport_size`, `center_px`, `params0 = (radius, illum, bright, dark)`, `params1 = (debug_mask_flag, waxing_sign, _, _)`, `params2 = (terminator_mode, terminator_width, terminator_bands, _)`. 64B total.
 - `starry-rs/starry-core/src/composite.wgsl` - Composite vertex (3-vert fullscreen triangle via `vertex_index`) + fragment (`textureLoad` passthrough — blending happens in the pipeline's blend state, not the shader).

**`starry-app/` — binary crate (winit shell; owns the Surface + main event loop):**
 - `starry-rs/starry-app/Cargo.toml` - Binary manifest. `[[bin]] name = "starry-app"`. Deps via `.workspace = true`: `starry-core` (path), wgpu, winit, pollster, log, env_logger, clap.
 - `starry-rs/starry-app/src/main.rs` - Entry point: env_logger init, `Config::parse()` via clap, dispatch to either the windowed path (`app::run`) or `starry_core::headless::dump_png(&config)`. Two `mod` declarations: `mod app; mod gpu;`.
 - `starry-rs/starry-app/src/app.rs` - winit `ApplicationHandler` impl: window creation, GPU lifecycle, redraw loop. Owns `Engine` (from `starry_core::engine`) and `WindowedGpu`; rebuilds `Engine` (preserving seed) on resize since the skyline geometry is resolution-dependent.
 - `starry-rs/starry-app/src/gpu.rs` - `WindowedGpu` — surface + swap-chain wrapper around `GpuPipelines`. Owns `Surface`, `SurfaceConfiguration`, and a `GpuPipelines` instance. Creates the wgpu Instance, picks adapter (high-perf, surface-compatible), creates Device+Queue, picks surface format (sRGB-preferred), then constructs `GpuPipelines`. `resize` reconfigures the surface then delegates. `render` acquires `SurfaceTexture`, handles `Lost`/`Outdated`/`Timeout`/`Other` error variants (reconfigure-and-retry, swallow-and-skip respectively), creates the view, calls `pipelines.render_to_view`, presents.

**Top-level:**
 - `starry-rs/README.md` - Build/run instructions, phased roadmap, CLI reference tables (Phase 2 + Phase 3 + Phase 4 + Phase 5a), headless usage, layout notes.
 - `starry-rs/PORT_PLAN.md` - In-tree engineering scratchpad: granular phase scoping, active todos, decisions log, validation history, open questions. Committed alongside the work it tracks; the user-facing roadmap lives in `README.md`.

### Conventions specific to the Rust side
 - **Pinned wgpu version.** Stay on `wgpu = "29"` until a deliberate, scoped upgrade. wgpu reshapes its API between minor releases — 29 alone introduced `experimental_features`, `multiview_mask`, `depth_slice`, and replaced `SurfaceError` with the `CurrentSurfaceTexture` enum. Bumping mid-port is a recipe for sadness. All version pins live in `starry-rs/Cargo.toml` under `[workspace.dependencies]`; member manifests pull in via `.workspace = true` so the wgpu pin (and every other dep version) is single-source.
 - **Workspace layout — `starry-core` (lib) + `starry-app` (bin).** `starry-core` owns all simulation + GPU pipeline + WGSL + headless code (window-agnostic; suitable for headless embedders and future tooling). `starry-app` is the thin winit shell: `Surface`, `SurfaceConfiguration`, instance/adapter/device/queue setup, main event loop, and CLI dispatch. The key split is in `gpu.rs`: `GpuPipelines` (in `starry-core`) owns Device+Queue+all pipelines and renders into a caller-supplied `&TextureView`; `WindowedGpu` (in `starry-app`) wraps `GpuPipelines` with a `Surface`. `default-members = ["starry-app"]` in the workspace `Cargo.toml` so `cargo run` from workspace root still targets the binary without needing `-p starry-app`.
 - **No re-exports in `starry-core/lib.rs`.** 19 `pub mod` declarations, no `pub use`. Call sites use explicit paths (`use starry_core::config::Config`) — keeps the import surface honest and avoids re-export drift.
 - **WGSL shaders live next to the `.rs` that includes them** (`shader.wgsl` next to `sprite.rs`, etc.). `include_str!()` paths are file-relative, so moving a `.rs`/`.wgsl` pair together requires zero shader-path edits.
 - **Wall-clock time is injected, not fetched.** Any simulation code that depends on real-world time (Phase 4 onwards: the moon phase, Phase 5a's planet ephemerides) takes a `wall_now: SystemTime` parameter rather than calling `SystemTime::now()` internally. The windowed shell (`app.rs`) passes `SystemTime::now()` from the redraw handler; headless (`headless.rs`) passes a hardcoded `UNIX_EPOCH + Duration::from_secs(HEADLESS_NOW_UNIX_SECS)` (2024-01-01 UTC) for byte-stable determinism. Same pattern as `dt` injection in Phase 3 — and same payoff: deterministic headless tests, no environment dependency.
 - **Visual ground-truth = Swift.** When porting a layer, read the Swift source carefully and match behavior pixel-ish-for-pixel-ish. [`METAL_RENDERER_MAP.md`](METAL_RENDERER_MAP.md) is the architectural cheat sheet (5 pipelines: spriteOver, spriteAdditive, decayInPlace, moon, composite; ping-pong layer textures).
 - **Determinism is a feature.** Both the windowed shell and headless mode seed all randomness from `Config::seed`. Resize rebuilds the `Engine` with the same seed so a given `(seed, w, h)` is reproducible.
 - **Headless SHA parity = gold-standard refactor test.** When refactoring shared code (Phase 3.5 was the first big trial run), `cargo run -- --dump-png /tmp/x.png` against the seed=42 1280×800 default and `shasum -a 256` it. A matching SHA against the pre-refactor baseline proves byte-for-byte parity of the entire simulation + skyline GPU path. Doesn't cover the windowed Surface acquisition path — that one always needs a human eyeball. **Current baselines**: Phase 2 = `c4fac4d7...`; Phase 3 + 3.5 (sky+sat+shoot, no moon) = `476e74bc...`; Phase 4 (sky+sat+shoot+moon, smooth-mode terminator default, wall_now = 2024-01-01 UTC) = `986155e2...`; Phase 5a default (sky+sat+shoot+moon+7 planets) = `bc6fd368...`; Phase 5a with `--planets-enabled false` = `986155e2...` (Phase-4 byte-identical, proving `Option<PlanetRenderer>` cleanly skips planet GPU resources).
 - **Rust style.** Standard `cargo fmt` + `cargo clippy --workspace --all-targets -- -D warnings` cleanliness. Same simplicity/readability bar as the Swift code — fancy optimizations only when they meaningfully help.


## Documentation Guidelines
Any changes to code must be paired with updates to the relevant documentation if they materially change behavior, file roles, or architecture. This includes (but is not limited to):
 - Adding, removing, or renaming source files → update the File Contents section above.
 - Changing the rendering pipeline → update [METAL_RENDERER_MAP.md](METAL_RENDERER_MAP.md).
 - Adding or completing a feature → update the Status checklist in [README.md](README.md).
 - Touching the Rust port (`starry-rs/`) → update [`starry-rs/README.md`](starry-rs/README.md) (phase status, file layout, dep versions) and the Rust section in this file when conventions change.


## Coding Guidelines
Simplicity and understandability are highly valued. Fancy performance optimizations should only be used if they will significantly improve rendering speed or efficiency. 

Swift best practices must be followed unless we have a tremendously compelling reason to deviate from them.


## Building, Installing & Running

The Xcode project has two targets:

| Target | Scheme | Product | What it is |
|--------|--------|---------|------------|
| `StarryExcuseForAMacScreensaver` | `StarryExcuseForAMacScreensaver` | `StarryExcuseForAMacScreensaver.saver` | The screensaver bundle |
| `StarryPreview` | `StarryPreview` | `StarryPreview.app` | Standalone preview app (borderless window, no System Prefs needed) |

### Build from the command line

```bash
# Build the screensaver bundle (Debug)
xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryExcuseForAMacScreensaver \
  -configuration Debug \
  build

# Build the preview app (Debug)
xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryPreview \
  -configuration Debug \
  build
```

Both products land in DerivedData:
```
~/Library/Developer/Xcode/DerivedData/StarryExcuseForAMacScreensaver-<hash>/Build/Products/Debug/
```

### Install the screensaver

Copy the built `.saver` bundle into the user Screen Savers directory:
```bash
BUILT="$(xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryExcuseForAMacScreensaver -showBuildSettings 2>/dev/null \
  | grep ' TARGET_BUILD_DIR' | xargs | cut -d' ' -f3)"

cp -R "$BUILT/StarryExcuseForAMacScreensaver.saver" ~/Library/Screen\ Savers/
```

After copying, open **System Settings → Screen Saver** and select it. (On first install macOS may prompt you to approve the bundle.)

### Run the preview app

The fastest way to visually verify changes — no screensaver activation required:
```bash
BUILT="$(xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryPreview -showBuildSettings 2>/dev/null \
  | grep ' TARGET_BUILD_DIR' | xargs | cut -d' ' -f3)"

open "$BUILT/StarryPreview.app"
```

Or equivalently, run the `StarryPreview` scheme directly from Xcode (⌘R with that scheme selected).

### Build & run the Rust port

The Rust crate is self-contained under `starry-rs/`. You need a Rust toolchain via [rustup](https://rustup.rs) (`sh.rustup.rs`); make sure `$HOME/.cargo/env` is sourced in your shell.

```bash
# Build the whole workspace (debug)
cargo build --manifest-path starry-rs/Cargo.toml --workspace

# Build + launch the window (workspace default-member is `starry-app`, so no -p needed)
cargo run --manifest-path starry-rs/Cargo.toml

# With logging
RUST_LOG=info cargo run --manifest-path starry-rs/Cargo.toml

# Clippy across the workspace
cargo clippy --manifest-path starry-rs/Cargo.toml --workspace --all-targets -- -D warnings

# Headless single-frame render (deterministic byte-stable PNG; great for refactor parity checks)
cargo run --manifest-path starry-rs/Cargo.toml -- --dump-png /tmp/starry.png
```

Or `cd starry-rs && cargo run`. See [`starry-rs/README.md`](starry-rs/README.md) for the full phased roadmap and CLI flag reference.


## Known Quirks

### Screensaver Defaults Live in a Sandboxed Container

On modern macOS (Ventura+), screensavers run inside the `com.apple.ScreenSaver.Engine.legacyScreenSaver` sandbox container. `ScreenSaverDefaults(forModuleWithName:)` persists preferences into that container's **ByHost** directory, not the user's global `~/Library/Preferences/`:

```
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/
  Data/Library/Preferences/ByHost/<bundle-id>.<hardware-uuid>.plist
```

This means a standalone app (like StarryPreview) can't read those settings through the normal `ScreenSaverDefaults` API — it resolves to a different, non-containerized location and finds nothing.

**Our workaround**: `PreviewAppDelegate.seedDefaultsFromScreenSaverContainer()` reads the plist directly from the container path and seeds the values into the local `ScreenSaverDefaults` instance before the engine starts. If the plist isn't found (screensaver was never configured), the built-in fallback defaults in `StarryDefaultsManager` take over gracefully.

**If this breaks after a macOS update**, check whether Apple changed:
 - The container name (`com.apple.ScreenSaver.Engine.legacyScreenSaver`)
 - The storage path within the container (`Data/Library/Preferences/ByHost/`)
 - The plist naming convention (`<bundle-id>.<hardware-uuid>.plist`)
